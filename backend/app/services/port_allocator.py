"""Port allocator for OpenClaw containers."""

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.models import OpenClawInstance


async def allocate_port(db: AsyncSession) -> int:
    """Find and return the next available port in the configured range."""
    result = await db.execute(
        select(OpenClawInstance.port).order_by(OpenClawInstance.port)
    )
    used_ports = {row[0] for row in result.all()}

    for port in range(settings.openclaw_port_range_start, settings.openclaw_port_range_end + 1):
        if port not in used_ports:
            return port

    raise RuntimeError("No available ports in the configured range")
