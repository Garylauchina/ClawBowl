"""Chat control endpoints – warmup only.

Chat traffic flows directly from iOS app to OpenClaw gateway via nginx.
This router only handles control-plane: warmup (start container, return
gateway direct-connect info).
"""

from __future__ import annotations

import logging

from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import get_current_user
from app.database import get_db
from app.models import User
from app.services.instance_manager import instance_manager

logger = logging.getLogger("clawbowl.chat")

router = APIRouter(prefix="/api/v2", tags=["chat"])


@router.post("/chat/warmup")
async def warmup(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Pre-warm the user's OpenClaw container and return direct-connect info."""
    instance = await instance_manager.ensure_running(user, db)

    return {
        "status": "warm",
        "gateway_url": f"/gw/{instance.port}",
        "gateway_token": instance.gateway_token,
        "session_key": f"clawbowl-{user.id}",
    }
