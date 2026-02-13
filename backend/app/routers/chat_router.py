"""Chat proxy endpoint – forwards requests to user's OpenClaw container."""

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import get_current_user
from app.database import get_db
from app.models import User
from app.schemas import ChatRequest
from app.services.instance_manager import instance_manager
from app.services.proxy import proxy_chat_request

router = APIRouter(prefix="/api/v2", tags=["chat"])


@router.post("/chat")
async def chat(
    body: ChatRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Send a chat message through the user's dedicated OpenClaw instance.

    The orchestrator ensures the user's container is running, then proxies
    the request.
    """
    # Ensure the user's OpenClaw instance is up
    instance = await instance_manager.ensure_running(user, db)

    # Proxy to the user's container
    messages = [{"role": m.role, "content": m.content} for m in body.messages]
    try:
        result = await proxy_chat_request(
            instance=instance,
            messages=messages,
            model=body.model,
            stream=body.stream,
        )
    except Exception as exc:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"OpenClaw instance error: {exc}",
        )

    return result
