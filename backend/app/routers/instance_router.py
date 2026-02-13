"""Instance management endpoints for users to inspect / restart their container."""

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import get_current_user
from app.database import get_db
from app.models import User
from app.schemas import InstanceStatusResponse, MessageResponse
from app.services.instance_manager import instance_manager

router = APIRouter(prefix="/api/v2/instance", tags=["instance"])


@router.get("/status", response_model=InstanceStatusResponse)
async def instance_status(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Return the current state of the user's OpenClaw instance."""
    inst = await instance_manager.get_instance(user.id, db)
    if inst is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="No instance found")
    return InstanceStatusResponse(
        state=inst.state,
        port=inst.port,
        container_name=inst.container_name,
        created_at=inst.created_at,
        last_active_at=inst.last_active_at,
    )


@router.post("/restart", response_model=MessageResponse)
async def restart_instance(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Force-restart the user's OpenClaw instance."""
    await instance_manager.restart_instance(user, db)
    return MessageResponse(message="Instance restarted successfully")


@router.post("/clear", response_model=MessageResponse)
async def clear_sessions(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Clear chat history by destroying and recreating the instance."""
    await instance_manager.destroy_instance(user.id, db)
    return MessageResponse(message="Session history cleared. A new instance will be created on next chat.")
