"""Docker container lifecycle manager for per-user OpenClaw instances."""

from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timedelta, timezone
from pathlib import Path

import docker
import docker.errors
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.database import async_session
from app.models import OpenClawInstance, User
from app.services.config_generator import generate_gateway_token, write_config
from app.services.port_allocator import allocate_port
from app.subscriptions.tier import get_tier

logger = logging.getLogger("clawbowl.instance_manager")

# Module-level Docker client (sync, used from async via run_in_executor)
_docker: docker.DockerClient | None = None


def _get_docker() -> docker.DockerClient:
    global _docker
    if _docker is None:
        _docker = docker.from_env()
    return _docker


class InstanceManager:
    """Manage per-user OpenClaw Docker containers."""

    # ── Public API ────────────────────────────────────────────────────

    async def ensure_running(self, user: User, db: AsyncSession) -> OpenClawInstance:
        """Make sure the user's OpenClaw instance is running. Create if needed."""
        result = await db.execute(
            select(OpenClawInstance).where(OpenClawInstance.user_id == user.id)
        )
        instance = result.scalar_one_or_none()

        if instance is None:
            instance = await self._create_instance(user, db)
        elif instance.state == "stopped":
            await self._start_instance(instance, db)
        elif instance.state == "error":
            await self._restart_instance(instance, db)
        elif instance.state == "running":
            # Verify container is actually alive
            if not await self._is_container_alive(instance):
                await self._start_instance(instance, db)

        # Update last active timestamp
        instance.last_active_at = datetime.now(timezone.utc)
        await db.commit()
        return instance

    async def get_instance(self, user_id: str, db: AsyncSession) -> OpenClawInstance | None:
        result = await db.execute(
            select(OpenClawInstance).where(OpenClawInstance.user_id == user_id)
        )
        return result.scalar_one_or_none()

    async def restart_instance(self, user: User, db: AsyncSession) -> OpenClawInstance:
        """Force-restart the user's instance."""
        instance = await self.get_instance(user.id, db)
        if instance is None:
            return await self._create_instance(user, db)
        await self._restart_instance(instance, db)
        return instance

    async def stop_instance(self, instance: OpenClawInstance, db: AsyncSession) -> None:
        """Stop a running instance."""
        await self._stop_container(instance)
        instance.state = "stopped"
        await db.commit()

    async def destroy_instance(self, user_id: str, db: AsyncSession) -> None:
        """Remove container and DB record completely."""
        instance = await self.get_instance(user_id, db)
        if instance is None:
            return
        await self._remove_container(instance)
        await db.delete(instance)
        await db.commit()

    async def stop_idle_instances(self) -> int:
        """Stop instances that have been idle longer than the configured timeout.

        Skips instances that have active cron jobs.
        Returns the number of instances stopped.
        """
        cutoff = datetime.now(timezone.utc) - timedelta(
            minutes=settings.openclaw_idle_timeout_minutes
        )
        stopped = 0
        async with async_session() as db:
            result = await db.execute(
                select(OpenClawInstance).where(
                    OpenClawInstance.state == "running",
                    OpenClawInstance.last_active_at < cutoff,
                )
            )
            idle_instances = result.scalars().all()
            for inst in idle_instances:
                if self._has_active_cron_jobs(inst):
                    logger.debug("Skipping idle stop for %s (has cron jobs)", inst.container_name)
                    continue
                try:
                    await self._stop_container(inst)
                    inst.state = "stopped"
                    stopped += 1
                    logger.info("Stopped idle instance %s (port %d)", inst.container_name, inst.port)
                except Exception:
                    logger.exception("Failed to stop idle instance %s", inst.container_name)
            await db.commit()
        return stopped

    def _has_active_cron_jobs(self, instance: OpenClawInstance) -> bool:
        """Check if the instance has any enabled cron jobs."""
        import json as _json
        jobs_path = Path(instance.config_path) / "cron" / "jobs.json"
        if not jobs_path.exists():
            return False
        try:
            data = _json.loads(jobs_path.read_text())
            return any(j.get("enabled", True) for j in data.get("jobs", []))
        except Exception:
            return False

    async def health_check_all(self) -> dict[str, str]:
        """Check health of all 'running' instances. Returns {container_name: status}."""
        results: dict[str, str] = {}
        async with async_session() as db:
            result = await db.execute(
                select(OpenClawInstance).where(OpenClawInstance.state == "running")
            )
            instances = result.scalars().all()
            for inst in instances:
                alive = await self._is_container_alive(inst)
                results[inst.container_name] = "healthy" if alive else "unhealthy"
                if not alive:
                    inst.state = "error"
                    logger.warning("Instance %s is unhealthy", inst.container_name)
            await db.commit()
        return results

    # ── Private helpers ───────────────────────────────────────────────

    async def _create_instance(self, user: User, db: AsyncSession) -> OpenClawInstance:
        """Provision a new container for the user."""
        port = await allocate_port(db)
        gateway_token = generate_gateway_token()
        container_name = f"clawbowl-{user.id[:8]}"

        data_path = Path(settings.openclaw_data_dir) / user.id
        config_dir = data_path / "config"
        workspace_dir = data_path / "workspace"
        snapshots_dir = data_path / "snapshots"
        workspace_dir.mkdir(parents=True, exist_ok=True)
        snapshots_dir.mkdir(parents=True, exist_ok=True)

        # Write per-user openclaw.json
        write_config(user, gateway_token, config_dir)

        # Create DB record first
        instance = OpenClawInstance(
            user_id=user.id,
            container_name=container_name,
            port=port,
            state="creating",
            gateway_token=gateway_token,
            config_path=str(config_dir),
            data_path=str(data_path),
        )
        db.add(instance)
        await db.flush()

        # Start Docker container
        tier = get_tier(user.subscription_tier)
        container = await asyncio.get_event_loop().run_in_executor(
            None,
            lambda: _get_docker().containers.run(
                image=settings.openclaw_image,
                name=container_name,
                ports={"18789/tcp": ("127.0.0.1", port)},
                volumes={
                    settings.openclaw_host_modules: {
                        "bind": "/usr/lib/node_modules/openclaw",
                        "mode": "ro",
                    },
                    str(config_dir): {"bind": "/data/config", "mode": "rw"},
                    str(workspace_dir): {"bind": "/data/workspace", "mode": "rw"},
                },
                environment={
                    "NODE_OPTIONS": f"--max-old-space-size={settings.openclaw_node_max_old_space}",
                    "OPENCLAW_STATE_DIR": "/data/config",
                },
                mem_limit=tier.container_memory,
                cpu_quota=int(tier.container_cpus * 100000),
                cpu_period=100000,
                restart_policy={"Name": "unless-stopped"},
                detach=True,
                network_mode="bridge",
                init=True,
            ),
        )

        instance.container_id = container.id
        instance.state = "running"
        await db.commit()

        # Wait for gateway to be ready (OpenClaw needs ~60-90s to start on low-spec VPS)
        await self._wait_for_ready(instance, timeout=120)

        # Auto-approve gateway device pairing so cron/gateway tools work
        await self._auto_approve_pairing(config_dir)

        logger.info("Created instance %s on port %d for user %s", container_name, port, user.id)
        return instance

    async def _start_instance(self, instance: OpenClawInstance, db: AsyncSession) -> None:
        """Start a stopped container."""
        try:
            await asyncio.get_event_loop().run_in_executor(
                None,
                lambda: _get_docker().containers.get(instance.container_name).start(),
            )
            instance.state = "running"
            await db.commit()
            await self._wait_for_ready(instance, timeout=30)
            logger.info("Started instance %s", instance.container_name)
        except docker.errors.NotFound:
            # Container was removed externally; re-create
            logger.warning("Container %s not found, recreating", instance.container_name)
            await db.delete(instance)
            await db.flush()
            user_result = await db.execute(
                select(User).where(User.id == instance.user_id)
            )
            user = user_result.scalar_one()
            await self._create_instance(user, db)

    async def _restart_instance(self, instance: OpenClawInstance, db: AsyncSession) -> None:
        """Restart a container."""
        try:
            await asyncio.get_event_loop().run_in_executor(
                None,
                lambda: _get_docker().containers.get(instance.container_name).restart(timeout=10),
            )
            instance.state = "running"
            await db.commit()
            await self._wait_for_ready(instance, timeout=30)
        except docker.errors.NotFound:
            await db.delete(instance)
            await db.flush()
            user_result = await db.execute(
                select(User).where(User.id == instance.user_id)
            )
            user = user_result.scalar_one()
            await self._create_instance(user, db)

    async def _stop_container(self, instance: OpenClawInstance) -> None:
        try:
            await asyncio.get_event_loop().run_in_executor(
                None,
                lambda: _get_docker().containers.get(instance.container_name).stop(timeout=10),
            )
        except docker.errors.NotFound:
            pass

    async def _remove_container(self, instance: OpenClawInstance) -> None:
        try:
            await asyncio.get_event_loop().run_in_executor(
                None,
                lambda: _get_docker().containers.get(instance.container_name).remove(force=True),
            )
        except docker.errors.NotFound:
            pass

    async def _is_container_alive(self, instance: OpenClawInstance) -> bool:
        try:
            container = await asyncio.get_event_loop().run_in_executor(
                None,
                lambda: _get_docker().containers.get(instance.container_name),
            )
            return container.status == "running"
        except docker.errors.NotFound:
            return False

    async def _auto_approve_pairing(self, config_dir: Path, retries: int = 5) -> None:
        """Auto-approve any pending gateway device pairing requests.

        The OpenClaw gateway-client generates a pairing request on first start.
        Without approval, tools like cron/gateway won't function.
        """
        import json as _json

        devices_dir = config_dir / "devices"
        pending_path = devices_dir / "pending.json"
        paired_path = devices_dir / "paired.json"

        for attempt in range(retries):
            await asyncio.sleep(3)
            if not pending_path.exists():
                continue
            try:
                pending = _json.loads(pending_path.read_text())
                if not pending:
                    continue

                paired = _json.loads(paired_path.read_text()) if paired_path.exists() else {}
                for req_id, device in pending.items():
                    device["approved"] = True
                    device["pairedAt"] = device.get("ts", 0)
                    paired[device.get("deviceId", req_id)] = device

                paired_path.write_text(_json.dumps(paired, indent=2))
                pending_path.write_text(_json.dumps({}))
                logger.info("Auto-approved %d gateway device pairing(s)", len(pending))
                return
            except Exception:
                logger.debug("Pairing auto-approve attempt %d failed", attempt + 1)
        logger.warning("No pending pairing requests found after %d attempts", retries)

    async def _wait_for_ready(self, instance: OpenClawInstance, timeout: int = 30) -> None:
        """Poll the gateway until it responds or timeout."""
        import httpx

        url = f"http://127.0.0.1:{instance.port}/v1/chat/completions"
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {instance.gateway_token}",
        }
        body = {"model": "test", "messages": []}

        deadline = asyncio.get_event_loop().time() + timeout
        while asyncio.get_event_loop().time() < deadline:
            try:
                async with httpx.AsyncClient(timeout=3) as client:
                    resp = await client.post(url, json=body, headers=headers)
                    # Any HTTP response (even 4xx/5xx) means the gateway is up
                    if resp.status_code > 0:
                        return
            except (httpx.ConnectError, httpx.ReadError, httpx.ConnectTimeout):
                pass
            await asyncio.sleep(2)
        logger.warning("Instance %s did not become ready within %ds", instance.container_name, timeout)


# Singleton
instance_manager = InstanceManager()
