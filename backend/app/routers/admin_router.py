"""Admin endpoints (placeholder for future management API)."""

from fastapi import APIRouter, Depends
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.models import OpenClawInstance, User

router = APIRouter(prefix="/api/v2/admin", tags=["admin"])

# TODO: add admin authentication (API key or admin role check)


@router.get("/stats")
async def stats(db: AsyncSession = Depends(get_db)):
    """Return basic system statistics."""
    user_count = await db.scalar(select(func.count(User.id)))
    instance_count = await db.scalar(select(func.count(OpenClawInstance.id)))
    running_count = await db.scalar(
        select(func.count(OpenClawInstance.id)).where(OpenClawInstance.state == "running")
    )
    return {
        "total_users": user_count,
        "total_instances": instance_count,
        "running_instances": running_count,
    }
