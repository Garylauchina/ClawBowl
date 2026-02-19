"""File download endpoint – serves files from user's OpenClaw workspace.

Security:
- JWT via Authorization header (POST bypasses CDN interception of GET requests)
- Path traversal protection (resolved path must be inside workspace)
- File existence check
"""

from __future__ import annotations

import logging
import mimetypes
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, Request, status
from fastapi.responses import FileResponse
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import decode_access_token
from app.database import get_db
from app.models import User
from app.services.instance_manager import instance_manager

logger = logging.getLogger("clawbowl.files")

router = APIRouter(prefix="/api/v2", tags=["files"])


class FileDownloadRequest(BaseModel):
    path: str
    token: str | None = None


async def _get_user_for_download(
    request: Request,
    body: FileDownloadRequest,
    db: AsyncSession = Depends(get_db),
) -> User:
    """Authenticate via body token (primary) or Authorization header (fallback)."""
    jwt_token = body.token

    if not jwt_token:
        auth_header = request.headers.get("authorization", "")
        if auth_header.startswith("Bearer "):
            jwt_token = auth_header[7:]

    if not jwt_token:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Not authenticated")

    user_id = decode_access_token(jwt_token)
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if user is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="User not found")
    return user


@router.post("/files/download")
async def download_file(
    body: FileDownloadRequest,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    """Download a file from the user's OpenClaw workspace (POST to bypass CDN).

    Body: ``{"path": "output/chart.png", "token": "<jwt>"}``
    """
    user = await _get_user_for_download(request, body, db)
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

    requested = body.path.replace("\\", "/")
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

    if not resolved.is_file():
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="File not found",
        )

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
