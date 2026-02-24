"""Chat control endpoints – warmup and session management.

Chat traffic flows directly from iOS app to OpenClaw gateway via WebSocket.
This router handles warmup (start container, return gateway + device auth info).
"""

from __future__ import annotations

import base64
import hashlib
import json
import logging
from datetime import datetime

from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
)
from cryptography.hazmat.primitives import serialization
from fastapi import APIRouter, Depends
from pathlib import Path
from pydantic import BaseModel
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
        "gateway_ws_url": f"ws://106.55.174.74:8080/gw/{instance.port}/",
        "gateway_token": instance.gateway_token,
        "session_key": session_key,
        "device_id": device["device_id"],
        "device_public_key": device["public_key_b64"],
        "device_private_key": device["private_key_b64"],
    }


class HistoryRequest(BaseModel):
    """Optional pagination: load older messages when scrolling up."""
    limit: int = 100
    before: int | None = None  # timestamp in ms; return messages older than this


def _ts_to_sortable(ts) -> float:
    """Normalize timestamp to seconds for sorting (OpenClaw may send ms or ISO)."""
    if ts is None:
        return 0.0
    if isinstance(ts, (int, float)):
        return float(ts) / 1000.0 if ts > 1e12 else float(ts)
    if isinstance(ts, str):
        ts = ts.strip()
        if not ts:
            return 0.0
        if ts.isdigit():
            v = float(ts)
            return v / 1000.0 if v > 1e12 else v
        for fmt in (
            "%Y-%m-%dT%H:%M:%S.%fZ",
            "%Y-%m-%dT%H:%M:%S.%f",
            "%Y-%m-%dT%H:%M:%SZ",
            "%Y-%m-%dT%H:%M:%S",
            "%Y-%m-%d %H:%M:%S",
            "%Y-%m-%d",
        ):
            try:
                s = ts[:26] if len(ts) >= 26 else ts
                return datetime.strptime(s, fmt).timestamp()
            except (ValueError, TypeError):
                continue
        import re
        iso_match = re.match(r"(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})", ts)
        if iso_match:
            try:
                return datetime(*map(int, iso_match.groups())).timestamp()
            except (ValueError, TypeError):
                pass
    return 0.0


@router.post("/chat/history")
async def chat_history(
    body: HistoryRequest | None = None,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Read chat history from OpenClaw session JSONL with pagination (Telegram-style).
    First page: no `before` → returns latest `limit` messages.
    Next page: `before` = oldestTimestamp from previous → returns older chunk.
    """
    req = body or HistoryRequest()
    limit = max(1, min(500, req.limit))
    instance = await instance_manager.ensure_running(user, db)
    session_key = f"clawbowl-{user.id}"
    sessions_dir = Path(instance.data_path) / "config" / "agents" / "main" / "sessions"
    sessions_json = sessions_dir / "sessions.json"

    if not sessions_json.exists():
        return {"messages": [], "hasMore": False, "sessionKey": session_key}

    try:
        sessions_data = json.loads(sessions_json.read_text())
    except Exception:
        return {"messages": [], "hasMore": False, "sessionKey": session_key}

    session_info = (
        sessions_data.get(session_key, {})
        or sessions_data.get(f"agent:main:{session_key}", {})
    )
    session_id = session_info.get("sessionId")
    if not session_id:
        return {"messages": [], "hasMore": False, "sessionKey": session_key}

    jsonl_path = sessions_dir / f"{session_id}.jsonl"
    if not jsonl_path.exists():
        return {"messages": [], "hasMore": False, "sessionKey": session_key}

    rows = []
    try:
        with open(jsonl_path, "r") as f:
            for line_idx, line in enumerate(f):
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if entry.get("type") != "message":
                    continue
                msg = entry.get("message", {})
                role = msg.get("role")
                if role not in ("user", "assistant"):
                    continue
                content = msg.get("content", "")
                if isinstance(content, list):
                    text = "".join(
                        p.get("text", "")
                        for p in content
                        if isinstance(p, dict) and p.get("type") == "text"
                    )
                elif isinstance(content, str):
                    text = content
                else:
                    continue
                if not text.strip():
                    continue
                ts_raw = entry.get("timestamp", "")
                ts_sort = _ts_to_sortable(ts_raw)
                rows.append({
                    "line_idx": line_idx,
                    "role": role,
                    "content": text,
                    "timestamp": ts_raw,
                    "ts_sort": ts_sort,
                })
    except Exception as e:
        logger.error("Failed to read session JSONL: %s", e)
        return {"messages": [], "hasMore": False, "sessionKey": session_key}

    rows.sort(key=lambda r: r["ts_sort"])
    before_sort = _ts_to_sortable(req.before) if req.before is not None else None
    if before_sort is not None:
        rows = [r for r in rows if r["ts_sort"] < before_sort]
    
    total_count = len(rows)
    has_more = total_count > limit
    start_idx = total_count - limit if has_more else 0
    chunk = rows[start_idx:]
    oldest_ts = chunk[0]["ts_sort"] * 1000 if chunk else None

    out = []
    for i, r in enumerate(chunk):
        # 统一返回毫秒时间戳，避免客户端解析 OpenCLaw 原始格式失败导致显示“刚才”
        ts_ms = int(r["ts_sort"] * 1000)
        out.append({
            "id": f"l{r['line_idx']}",
            "role": r["role"],
            "content": r["content"],
            "timestamp": ts_ms,
        })

    return {
        "messages": out,
        "hasMore": has_more,
        "oldestTimestamp": int(oldest_ts) if oldest_ts is not None else None,
        "sessionKey": session_key,
    }
