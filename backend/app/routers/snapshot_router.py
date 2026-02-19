"""Snapshot management endpoints - create, list, restore workspace backups."""

from __future__ import annotations

import logging

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import get_current_user
from app.database import get_db
from app.models import User
from app.services.instance_manager import instance_manager
from app.services.snapshot_service import (
    cleanup_snapshots,
    create_snapshot,
    list_snapshots,
    restore_snapshot,
)

logger = logging.getLogger("clawbowl.snapshot")

router = APIRouter(prefix="/api/v2/snapshots", tags=["snapshots"])


@router.post("")
async def create_snap(
    source: str = "manual",
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Create a workspace snapshot (tar.zst + manifest.json)."""
    inst = await instance_manager.get_instance(user.id, db)
    if inst is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "No instance found")

    try:
        manifest = await create_snapshot(inst, source=source)
        await cleanup_snapshots(inst, keep_count=3)
        return manifest
    except Exception as exc:
        logger.exception("Snapshot creation failed for user %s", user.id)
        raise HTTPException(status.HTTP_500_INTERNAL_SERVER_ERROR, str(exc)) from exc


@router.get("")
async def list_snaps(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """List all snapshots for the current user."""
    inst = await instance_manager.get_instance(user.id, db)
    if inst is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "No instance found")

    return await list_snapshots(inst)


@router.post("/{snap_id}/restore")
async def restore_snap(
    snap_id: str,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Restore workspace from a specific snapshot."""
    inst = await instance_manager.get_instance(user.id, db)
    if inst is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "No instance found")

    try:
        await create_snapshot(inst, source="pre_restore")
    except Exception:
        logger.warning("Pre-restore snapshot failed, proceeding anyway")

    try:
        await restore_snapshot(inst, snap_id)
        return {"status": "restored", "snap_id": snap_id}
    except FileNotFoundError:
        raise HTTPException(status.HTTP_404_NOT_FOUND, f"Snapshot {snap_id} not found")
    except ValueError as exc:
        raise HTTPException(status.HTTP_409_CONFLICT, str(exc))
    except Exception as exc:
        logger.exception("Snapshot restore failed for user %s", user.id)
        raise HTTPException(status.HTTP_500_INTERNAL_SERVER_ERROR, str(exc)) from exc
