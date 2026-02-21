"""Chat control endpoints – warmup and session management.

Chat traffic flows directly from iOS app to OpenClaw gateway via WebSocket.
This router handles warmup (start container, return gateway + device auth info).
"""

from __future__ import annotations

import base64
import hashlib
import json
import logging

from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
)
from cryptography.hazmat.primitives import serialization
from fastapi import APIRouter, Depends
from pathlib import Path
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import get_current_user
from app.database import get_db
from app.models import User
from app.services.instance_manager import instance_manager

logger = logging.getLogger("clawbowl.chat")

router = APIRouter(prefix="/api/v2", tags=["chat"])


def _b64url_encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _ensure_ios_device(config_dir: Path) -> dict:
    """Ensure an iOS device entry exists in paired.json.

    Returns dict with device_id, public_key_b64, private_key_b64.
    Creates a new Ed25519 keypair if no iOS device is registered yet.
    Uses sudo for writes since the devices dir is owned by root (Docker).
    """
    import subprocess
    import time

    devices_dir = config_dir / "devices"
    paired_path = devices_dir / "paired.json"
    privkey_path = devices_dir / "ios_device.key"

    paired: dict = {}
    if paired_path.exists():
        try:
            paired = json.loads(paired_path.read_text())
        except Exception:
            pass

    for dev_id, dev in paired.items():
        if dev.get("clientId") == "openclaw-ios" and privkey_path.exists():
            priv_b64 = privkey_path.read_text().strip()
            return {
                "device_id": dev_id,
                "public_key_b64": dev.get("publicKey", ""),
                "private_key_b64": priv_b64,
            }

    private_key = Ed25519PrivateKey.generate()
    pub_bytes = private_key.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw
    )
    priv_bytes = private_key.private_bytes(
        serialization.Encoding.Raw,
        serialization.PrivateFormat.Raw,
        serialization.NoEncryption(),
    )
    pub_b64 = _b64url_encode(pub_bytes)
    priv_b64 = _b64url_encode(priv_bytes)
    device_id = hashlib.sha256(pub_bytes).hexdigest()

    ts = int(time.time() * 1000)
    scopes = [
        "operator.admin", "operator.approvals", "operator.pairing",
        "operator.read", "operator.write",
    ]
    paired[device_id] = {
        "requestId": "ios-provisioned",
        "deviceId": device_id,
        "publicKey": pub_b64,
        "platform": "ios",
        "clientId": "openclaw-ios",
        "clientMode": "cli",
        "role": "operator",
        "roles": ["operator"],
        "scopes": scopes,
        "silent": False,
        "isRepair": False,
        "ts": ts,
        "approved": True,
        "pairedAt": ts,
        "tokens": {
            "operator": {
                "token": "",
                "role": "operator",
                "scopes": scopes,
                "createdAtMs": ts,
                "rotatedAtMs": ts,
            }
        },
    }

    subprocess.run(
        ["sudo", "tee", str(paired_path)],
        input=json.dumps(paired, indent=2).encode(),
        capture_output=True, timeout=5,
    )
    subprocess.run(
        ["sudo", "tee", str(privkey_path)],
        input=priv_b64.encode(),
        capture_output=True, timeout=5,
    )
    subprocess.run(
        ["sudo", "chmod", "644", str(privkey_path)],
        capture_output=True, timeout=5,
    )
    subprocess.run(
        ["sudo", "chmod", "-R", "o+rX", str(devices_dir)],
        capture_output=True, timeout=5,
    )
    logger.info("Provisioned iOS device %s", device_id[:16])

    return {
        "device_id": device_id,
        "public_key_b64": pub_b64,
        "private_key_b64": priv_b64,
    }


@router.post("/chat/warmup")
async def warmup(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Pre-warm container and return gateway + device auth info for WebSocket."""
    instance = await instance_manager.ensure_running(user, db)

    session_key = f"clawbowl-{user.id}"
    config_dir = Path(instance.data_path) / "config"
    device = _ensure_ios_device(config_dir)

    return {
        "status": "warm",
        "gateway_url": f"/gw/{instance.port}",
        "gateway_ws_url": f"wss://api.prometheusclothing.net/gw/{instance.port}/",
        "gateway_token": instance.gateway_token,
        "session_key": session_key,
        "device_id": device["device_id"],
        "device_public_key": device["public_key_b64"],
        "device_private_key": device["private_key_b64"],
    }
