"""Chat proxy endpoint – forwards requests to user's OpenClaw container."""

import logging

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import get_current_user
from app.database import get_db
from app.models import User
from app.schemas import ChatRequest
from app.services.instance_manager import instance_manager
from app.services.proxy import proxy_chat_request

logger = logging.getLogger("clawbowl.chat")

router = APIRouter(prefix="/api/v2", tags=["chat"])


@router.post("/chat")
async def chat(
    body: ChatRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Send a chat message through the user's dedicated OpenClaw instance."""
    instance = await instance_manager.ensure_running(user, db)

    messages = [{"role": m.role, "content": m.content} for m in body.messages]

    # 日志：检测是否多模态
    has_image = any(
        isinstance(m.get("content"), list) for m in messages
    )
    logger.info("Chat request: user=%s, msgs=%d, has_image=%s", user.id, len(messages), has_image)

    try:
        result = await proxy_chat_request(
            instance=instance,
            messages=messages,
            model=body.model,
            stream=body.stream,
        )
    except Exception as exc:
        logger.error("Proxy error for user %s: %s", user.id, exc, exc_info=True)
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"OpenClaw instance error: {exc}",
        )

    return result
