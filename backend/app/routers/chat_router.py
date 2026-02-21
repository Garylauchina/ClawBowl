"""Chat control endpoints – warmup and session management.

Chat traffic now flows directly from the iOS app to the OpenClaw
gateway via nginx (see /gw/{port}/ location block).  This router
only handles control-plane operations:
- GET  /chat/warmup  — start container, return gateway direct-connect info
- POST /chat/cancel   — (legacy, kept for compat)
- POST /chat/history  — merged history from chat_logs + JSONL session files
"""

from __future__ import annotations

import json
import logging
import pathlib
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import get_current_user
from app.database import get_db
from app.models import ChatLog, OpenClawInstance, User
from app.schemas import ChatHistoryRequest
from app.services.instance_manager import instance_manager

logger = logging.getLogger("clawbowl.chat")

router = APIRouter(prefix="/api/v2", tags=["chat"])


# ── Endpoints ────────────────────────────────────────────────────────

@router.post("/chat/warmup")
async def warmup(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Pre-warm the user's OpenClaw container and return direct-connect info.

    Called by the iOS SplashView so the container is ready when the
    user reaches the ChatView.  Returns gateway URL and token for
    the app to connect directly to the OpenClaw gateway via nginx,
    bypassing the Python backend for chat traffic.
    """
    instance = await instance_manager.ensure_running(user, db)

    return {
        "status": "warm",
        "gateway_url": f"/gw/{instance.port}",
        "gateway_token": instance.gateway_token,
        "session_key": f"clawbowl-{user.id}",
    }


@router.post("/chat/cancel")
async def cancel_chat(
    user: User = Depends(get_current_user),
):
    """Legacy cancel endpoint — kept for backward compatibility.

    With direct gateway connection, the iOS app cancels streams by
    closing the URLSession connection.  This endpoint is a no-op.
    """
    return {"cancelled": False}


@router.post("/chat/history")
async def chat_history(
    body: ChatHistoryRequest = ChatHistoryRequest(),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Merged chat history: chat_logs (old) + JSONL session files (new)."""

    # 1. chat_logs (pre-V14)
    stmt = (
        select(ChatLog)
        .where(ChatLog.user_id == user.id)
        .where(ChatLog.status.notin_(["filtered"]))
    )
    if body.before:
        try:
            ts = datetime.fromisoformat(body.before)
        except ValueError:
            raise HTTPException(status_code=400, detail="Invalid 'before' timestamp")
        stmt = stmt.where(ChatLog.created_at < ts)
    if body.after:
        try:
            ts = datetime.fromisoformat(body.after)
        except ValueError:
            raise HTTPException(status_code=400, detail="Invalid 'after' timestamp")
        stmt = stmt.where(ChatLog.created_at > ts)

    stmt = stmt.order_by(ChatLog.created_at.desc()).limit(body.limit + 1)
    result = await db.execute(stmt)
    rows = result.scalars().all()

    has_more = len(rows) > body.limit
    rows = rows[: body.limit]
    rows.reverse()

    messages = []
    seen_ts = set()
    for r in rows:
        ts_iso = r.created_at.isoformat() if r.created_at else None
        messages.append({
            "id": r.id,
            "event_id": r.event_id,
            "role": r.role,
            "content": r.content,
            "thinking_text": r.thinking_text,
            "status": r.status,
            "created_at": ts_iso,
            "attachment_paths": json.loads(r.attachment_paths) if r.attachment_paths else None,
        })
        if ts_iso:
            seen_ts.add(ts_iso[:19])

    # 2. JSONL session files (post-V14 direct gateway messages)
    inst_result = await db.execute(
        select(OpenClawInstance).where(OpenClawInstance.user_id == user.id)
    )
    inst = inst_result.scalar_one_or_none()
    if inst:
        jsonl_msgs = _read_jsonl_sessions(inst.data_path, seen_ts, body.limit)
        messages.extend(jsonl_msgs)

    messages.sort(key=lambda m: m.get("created_at") or "")
    if len(messages) > body.limit:
        has_more = True
        messages = messages[-body.limit:]

    return {"messages": messages, "has_more": has_more}


def _read_jsonl_sessions(
    data_path: str, seen_ts: set[str], limit: int
) -> list[dict]:
    """Read user/assistant messages from all JSONL session files."""
    sessions_dir = pathlib.Path(data_path) / "config" / "agents" / "main" / "sessions"
    if not sessions_dir.is_dir():
        return []

    results = []
    for jf in sessions_dir.glob("*.jsonl"):
        if jf.name == "sessions.json":
            continue
        try:
            with open(jf) as fh:
                for line in fh:
                    entry = json.loads(line)
                    if entry.get("type") != "message":
                        continue
                    msg = entry.get("message", {})
                    role = msg.get("role")
                    if role not in ("user", "assistant"):
                        continue
                    content = msg.get("content", "")
                    if isinstance(content, list):
                        content = "".join(
                            p.get("text", "")
                            for p in content
                            if p.get("type") == "text"
                        )
                    if not content or not isinstance(content, str):
                        continue
                    # Skip system-injected context messages
                    if content.startswith("[Chat messages since"):
                        continue
                    if content.startswith("Read HEARTBEAT"):
                        continue
                    if content.startswith("Continue where you left off"):
                        continue

                    ts_str = entry.get("timestamp", "")
                    # Dedup against chat_logs by timestamp prefix
                    if ts_str[:19] in seen_ts:
                        continue

                    ts_iso = _normalize_ts(ts_str)

                    results.append({
                        "id": entry.get("id", ""),
                        "event_id": None,
                        "role": role,
                        "content": content,
                        "thinking_text": None,
                        "status": "success",
                        "created_at": ts_iso,
                        "attachment_paths": None,
                    })
        except Exception:
            logger.debug("Failed to read JSONL %s", jf, exc_info=True)
            continue

    results.sort(key=lambda m: m.get("created_at") or "")
    return results


def _normalize_ts(ts: str) -> str:
    """Convert '2026-02-21T04:03:39.062Z' to '2026-02-21T04:03:39.062000'."""
    if ts.endswith("Z"):
        ts = ts[:-1]
    if "." in ts:
        base, frac = ts.rsplit(".", 1)
        frac = frac.ljust(6, "0")[:6]
        return f"{base}.{frac}"
    return ts
