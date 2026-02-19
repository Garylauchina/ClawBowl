"""Background monitor that watches workspace .alerts.jsonl and triggers APNs push."""

from __future__ import annotations

import asyncio
import json
import logging
from pathlib import Path

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.database import async_session
from app.models import OpenClawInstance
from app.services.apns_service import send_push_to_user

logger = logging.getLogger("clawbowl.alert_monitor")

_POLL_INTERVAL = 60  # seconds
_offsets: dict[str, int] = {}  # user_id -> last processed byte offset


def _alerts_path(instance: OpenClawInstance) -> Path:
    return Path(instance.data_path) / "workspace" / ".alerts.jsonl"


def _read_new_alerts(path: Path, user_id: str) -> list[dict]:
    """Read new lines from .alerts.jsonl since last offset."""
    if not path.exists():
        return []

    offset = _offsets.get(user_id, 0)
    file_size = path.stat().st_size

    if file_size <= offset:
        if file_size < offset:
            _offsets[user_id] = 0
            offset = 0
        else:
            return []

    alerts = []
    try:
        with open(path, "r", encoding="utf-8") as f:
            f.seek(offset)
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    alert = json.loads(line)
                    if isinstance(alert, dict) and "title" in alert:
                        alerts.append(alert)
                except json.JSONDecodeError:
                    logger.debug("Skipping invalid JSON line in alerts: %s", line[:100])
            _offsets[user_id] = f.tell()
    except OSError as exc:
        logger.warning("Failed to read alerts for %s: %s", user_id, exc)

    return alerts


async def _process_alerts() -> None:
    """One pass: check all instances for new alerts and send pushes."""
    async with async_session() as db:
        result = await db.execute(
            select(OpenClawInstance).where(OpenClawInstance.state == "running")
        )
        instances = result.scalars().all()

        for inst in instances:
            path = _alerts_path(inst)
            alerts = _read_new_alerts(path, inst.user_id)

            for alert in alerts:
                title = alert.get("title", "ClawBowl Alert")
                body = alert.get("body", "")
                logger.info("Sending push to user %s: %s", inst.user_id, title)
                try:
                    sent = await send_push_to_user(
                        inst.user_id, db,
                        title=title,
                        body=body,
                        data={"alert_type": alert.get("type", "cron")},
                    )
                    if sent:
                        logger.info("Push sent (%d devices) for user %s", sent, inst.user_id)
                    else:
                        logger.debug("No devices to push for user %s", inst.user_id)
                except Exception:
                    logger.exception("Failed to send push for alert: %s", title)


async def alert_monitor_loop() -> None:
    """Main loop — runs forever, polling for alerts."""
    logger.info("Alert monitor started (poll every %ds)", _POLL_INTERVAL)
    while True:
        try:
            await _process_alerts()
        except Exception:
            logger.exception("Alert monitor error")
        await asyncio.sleep(_POLL_INTERVAL)
