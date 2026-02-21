"""Chat control endpoints – warmup and session management.

Chat traffic now flows directly from the iOS app to the OpenClaw
gateway via nginx (see /gw/{port}/ location block).  This router
only handles control-plane operations:
- GET  /chat/warmup  — start container, return gateway direct-connect info
- POST /chat/cancel   — (legacy, kept for compat)
- POST /chat/history  — (legacy, reads from chat_logs for old data)
"""

from __future__ import annotations

import json
import logging
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import get_current_user
from app.database import get_db
from app.models import ChatLog, User
from app.schemas import ChatHistoryRequest
from app.services.instance_manager import instance_manager

logger = logging.getLogger("clawbowl.chat")

router = APIRouter(prefix="/api/v2", tags=["chat"])


# ── Endpoints ────────────────────────────────────────────────────────

@router.get("/chat/warmup")
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
    """Legacy paginated chat history from chat_logs.

    This reads from the old chat_logs table (data from before the
    switch to direct gateway connection).  New messages are stored
    locally on the iOS device and in OpenClaw session JSONL files.
    """
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
    rows = rows[:body.limit]
    rows.reverse()

    messages = []
    for r in rows:
        messages.append({
            "id": r.id,
            "event_id": r.event_id,
            "role": r.role,
            "content": r.content,
            "thinking_text": r.thinking_text,
            "status": r.status,
            "created_at": r.created_at.isoformat() if r.created_at else None,
            "attachment_paths": json.loads(r.attachment_paths) if r.attachment_paths else None,
        })

    return {"messages": messages, "has_more": has_more}
