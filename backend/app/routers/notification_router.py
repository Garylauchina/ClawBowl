"""Push notification endpoints — device token registration and notification list."""

from __future__ import annotations

import logging

from fastapi import APIRouter, Depends
from pydantic import BaseModel
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import get_current_user
from app.database import get_db
from app.models import DeviceToken, User

logger = logging.getLogger("clawbowl.notifications")

router = APIRouter(prefix="/api/v2/notifications", tags=["notifications"])


class RegisterTokenRequest(BaseModel):
    token: str
    platform: str = "ios"


@router.post("/register")
async def register_device_token(
    body: RegisterTokenRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Register or update an APNs device token for the current user."""
    result = await db.execute(
        select(DeviceToken).where(DeviceToken.token == body.token)
    )
    existing = result.scalar_one_or_none()

    if existing:
        existing.user_id = user.id
        existing.platform = body.platform
    else:
        await db.execute(
            delete(DeviceToken).where(
                DeviceToken.user_id == user.id,
                DeviceToken.platform == body.platform,
            )
        )
        db.add(DeviceToken(
            user_id=user.id,
            token=body.token,
            platform=body.platform,
        ))

    await db.commit()
    logger.info("Device token registered for user %s", user.id)
    return {"status": "ok"}
