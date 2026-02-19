"""Apple Push Notification Service (APNs) client using HTTP/2 + JWT."""

from __future__ import annotations

import json
import logging
import time
from pathlib import Path

import httpx
import jwt
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.models import DeviceToken

logger = logging.getLogger("clawbowl.apns")

_APNS_PROD = "https://api.push.apple.com"
_APNS_SANDBOX = "https://api.sandbox.push.apple.com"

_jwt_token: str | None = None
_jwt_issued_at: float = 0
_JWT_LIFETIME = 3500  # refresh before 1-hour expiry


def _is_configured() -> bool:
    return bool(settings.apns_key_path and settings.apns_key_id and settings.apns_team_id)


def _load_signing_key() -> str:
    return Path(settings.apns_key_path).read_text()


def _get_jwt_token() -> str:
    global _jwt_token, _jwt_issued_at

    now = time.time()
    if _jwt_token and (now - _jwt_issued_at) < _JWT_LIFETIME:
        return _jwt_token

    signing_key = _load_signing_key()
    _jwt_issued_at = now
    _jwt_token = jwt.encode(
        {"iss": settings.apns_team_id, "iat": int(now)},
        signing_key,
        algorithm="ES256",
        headers={"kid": settings.apns_key_id},
    )
    return _jwt_token


def _apns_url() -> str:
    return _APNS_SANDBOX if settings.apns_use_sandbox else _APNS_PROD


async def send_push(
    device_token: str,
    title: str,
    body: str,
    badge: int | None = None,
    category: str | None = None,
    data: dict | None = None,
) -> bool:
    """Send a single push notification. Returns True on success."""
    if not _is_configured():
        logger.warning("APNs not configured, skipping push")
        return False

    token = _get_jwt_token()
    url = f"{_apns_url()}/3/device/{device_token}"

    payload: dict = {
        "aps": {
            "alert": {"title": title, "body": body},
            "sound": "default",
        }
    }
    if badge is not None:
        payload["aps"]["badge"] = badge
    if category:
        payload["aps"]["category"] = category
    if data:
        payload.update(data)

    headers = {
        "authorization": f"bearer {token}",
        "apns-topic": settings.apns_bundle_id,
        "apns-push-type": "alert",
        "apns-priority": "10",
    }

    try:
        async with httpx.AsyncClient(http2=True, timeout=10) as client:
            resp = await client.post(url, json=payload, headers=headers)
            if resp.status_code == 200:
                logger.info("Push sent to %s...%s", device_token[:8], device_token[-4:])
                return True
            else:
                body_text = resp.text
                logger.warning(
                    "APNs error %d for %s: %s",
                    resp.status_code, device_token[:8], body_text[:200],
                )
                return False
    except Exception:
        logger.exception("Failed to send push to %s", device_token[:8])
        return False


async def send_push_to_user(
    user_id: str,
    db: AsyncSession,
    title: str,
    body: str,
    badge: int | None = None,
    data: dict | None = None,
) -> int:
    """Send push to all devices of a user. Returns count of successful sends."""
    result = await db.execute(
        select(DeviceToken).where(DeviceToken.user_id == user_id)
    )
    tokens = result.scalars().all()

    sent = 0
    for dt in tokens:
        ok = await send_push(dt.token, title, body, badge=badge, data=data)
        if ok:
            sent += 1
    return sent
