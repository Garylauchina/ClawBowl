"""Docker container lifecycle manager for per-user OpenClaw instances."""

from __future__ import annotations

import asyncio
import json as _json
import logging
import shutil
from datetime import datetime, timedelta, timezone
from pathlib import Path

import docker
import docker.errors
from jinja2 import Environment, FileSystemLoader
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.database import async_session
from app.models import OpenClawInstance, User
from app.services.config_generator import (
    generate_gateway_token,
    read_hooks_token,
    write_config,
)
from app.services.port_allocator import allocate_port

logger = logging.getLogger("clawbowl.instance_manager")

_TEMPLATES_DIR = Path(__file__).resolve().parent.parent.parent / "templates"

# Module-level Docker client (sync, used from async via run_in_executor)
_docker: docker.DockerClient | None = None


def _get_docker() -> docker.DockerClient:
    global _docker
    if _docker is None:
        _docker = docker.from_env()
    return _docker


def _init_workspace(user: User, workspace_dir: Path, config_dir: Path) -> None:
    """Render workspace templates into a new user's workspace directory.

    Only writes files that don't already exist — safe to call on existing users.
    Also creates cron/jobs.json in the config directory if missing.
    """
    ws_template_dir = _TEMPLATES_DIR / "workspace"
    if not ws_template_dir.is_dir():
        logger.warning("Workspace templates dir not found: %s", ws_template_dir)
        return

    now = datetime.now(timezone.utc)
    context = {
        "USER_NAME": user.username,
        "USER_LANGUAGE": "中文",
        "USER_TIMEZONE": "Asia/Shanghai",
        "AGENT_NAME": "Claw",
        "CREATION_DATE": now.strftime("%Y-%m-%d"),
        "TAVILY_API_KEY": settings.tavily_api_key or "",
    }

    env = Environment(
        loader=FileSystemLoader(str(ws_template_dir)),
        keep_trailing_newline=True,
    )

    for tpl_path in ws_template_dir.rglob("*"):
        if tpl_path.is_dir():
            continue

        rel = tpl_path.relative_to(ws_template_dir)

        if tpl_path.suffix == ".j2":
            dest = workspace_dir / str(rel).removesuffix(".j2")
        else:
            dest = workspace_dir / rel

        if dest.exists():
            continue

        dest.parent.mkdir(parents=True, exist_ok=True)

        if tpl_path.suffix == ".j2":
            template = env.get_template(str(rel))
            dest.write_text(template.render(**context), encoding="utf-8")
            logger.debug("Rendered workspace template: %s", dest.name)
        else:
            shutil.copy2(tpl_path, dest)
            logger.debug("Copied workspace file: %s", dest.name)

    cron_dir = config_dir / "cron"
    cron_dir.mkdir(parents=True, exist_ok=True)
    jobs_file = cron_dir / "jobs.json"
    if not jobs_file.exists():
        cron_init_src = _TEMPLATES_DIR / "instance" / "cron-init.json"
        if cron_init_src.exists():
            shutil.copy2(cron_init_src, jobs_file)
        else:
            jobs_file.write_text('{"version": 1, "jobs": []}\n', encoding="utf-8")

    memory_dir = workspace_dir / "memory"
    memory_dir.mkdir(parents=True, exist_ok=True)

    logger.info("Initialized workspace for user %s", user.username)


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

        # Ensure session files are readable for history retrieval
        await self._fix_session_permissions(Path(instance.data_path) / "config")

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
        workspace_dir.mkdir(parents=True, exist_ok=True)

        # Write per-user openclaw.json
        write_config(user, gateway_token, config_dir)

        # Populate workspace with templates (agent "birth pack")
        _init_workspace(user, workspace_dir, config_dir)

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
                mem_limit=settings.openclaw_container_memory,
                cpu_quota=int(settings.openclaw_container_cpus * 100000),
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

        # Make session files readable by the backend for reconciliation
        await self._fix_session_permissions(config_dir)

        logger.info("Created instance %s on port %d for user %s", container_name, port, user.id)
        return instance

    async def _sync_config(self, instance: OpenClawInstance, db: AsyncSession) -> None:
        """Re-render openclaw.json from the latest template while preserving
        user-specific runtime values (hooks_token).

        Called before every start / restart so that template changes (new
        features, security fixes, model updates) are automatically picked up
        by existing users without requiring a full container re-creation.
        """
        config_dir = Path(instance.config_path)
        user_result = await db.execute(
            select(User).where(User.id == instance.user_id)
        )
        user = user_result.scalar_one()

        existing_hooks_token = read_hooks_token(config_dir)
        write_config(
            user,
            instance.gateway_token,
            config_dir,
            hooks_token=existing_hooks_token,
        )
        logger.info(
            "Synced config from template for %s (hooks_token preserved: %s)",
            instance.container_name,
            existing_hooks_token is not None,
        )

    async def _start_instance(self, instance: OpenClawInstance, db: AsyncSession) -> None:
        """Start a stopped container."""
        try:
            await self._sync_config(instance, db)
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
            await self._sync_config(instance, db)
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

    @staticmethod
    async def _fix_session_permissions(config_dir: Path) -> None:
        """Ensure OpenClaw session files are readable by the backend process.

        Uses ``sudo chmod`` since the files are owned by root (container).
        The entrypoint.sh ``umask 0022`` handles new files; this fixes old ones.
        """
        import subprocess

        agents_dir = config_dir / "agents"
        if agents_dir.exists():
            try:
                await asyncio.get_event_loop().run_in_executor(
                    None,
                    lambda: subprocess.run(
                        ["sudo", "chmod", "-R", "o+rX", str(agents_dir)],
                        timeout=5, capture_output=True,
                    ),
                )
            except Exception:
                pass

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
