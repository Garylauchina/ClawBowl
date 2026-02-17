"""File download endpoint – serves files from user's OpenClaw workspace.

Security:
- JWT authentication (reuses get_current_user)
- Path traversal protection (resolved path must be inside workspace)
- File existence check
"""

from __future__ import annotations

import logging
import mimetypes
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, Query, status
from fastapi.responses import FileResponse
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import get_current_user
from app.database import get_db
from app.models import User
from app.services.instance_manager import instance_manager

logger = logging.getLogger("clawbowl.files")

router = APIRouter(prefix="/api/v2", tags=["files"])


@router.get("/files/download")
async def download_file(
    path: str = Query(..., description="Workspace-relative file path"),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Download a file from the user's OpenClaw workspace.

    The path is relative to the workspace root, e.g. ``output/chart.png``.
    """
    # 1. Get user's instance to locate workspace
    inst = await instance_manager.get_instance(user.id, db)
    if inst is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="No active instance",
        )

    workspace_dir = Path(inst.data_path) / "workspace"
    if not workspace_dir.is_dir():
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Workspace not found",
        )

    # 2. Path traversal protection
    requested = path.replace("\\", "/")
    if ".." in requested.split("/"):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Invalid path",
        )

    resolved = (workspace_dir / requested).resolve()
    if not resolved.is_relative_to(workspace_dir.resolve()):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Invalid path",
        )

    # 3. File existence check
    if not resolved.is_file():
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="File not found",
        )

    # 4. Determine MIME type
    mime_type, _ = mimetypes.guess_type(resolved.name)
    if mime_type is None:
        mime_type = "application/octet-stream"

    logger.info(
        "File download: user=%s path=%s size=%d",
        user.id, requested, resolved.stat().st_size,
    )

    return FileResponse(
        path=str(resolved),
        media_type=mime_type,
        filename=resolved.name,
    )
