"""File download endpoint – serves files from user's OpenClaw workspace.

Security:
- JWT authentication via query parameter token (avoids Cloudflare header interference)
- Fallback to Authorization header for direct/curl access
- Path traversal protection (resolved path must be inside workspace)
- File existence check
"""

from __future__ import annotations

import logging
import mimetypes
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from fastapi.responses import FileResponse
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import decode_access_token
from app.database import get_db
from app.models import User
from app.services.instance_manager import instance_manager

logger = logging.getLogger("clawbowl.files")

router = APIRouter(prefix="/api/v2", tags=["files"])


async def _get_user_from_token_param(
    request: Request,
    token: str | None = Query(None, description="JWT access token"),
    db: AsyncSession = Depends(get_db),
) -> User:
    """Authenticate via query parameter `token` (primary) or Authorization header (fallback).

    Query parameter auth avoids Cloudflare stripping/blocking Authorization headers
    on GET requests for binary content.
    """
    jwt_token = token

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


@router.get("/files/download")
async def download_file(
    path: str = Query(..., description="Workspace-relative file path"),
    user: User = Depends(_get_user_from_token_param),
    db: AsyncSession = Depends(get_db),
):
    """Download a file from the user's OpenClaw workspace.

    The path is relative to the workspace root, e.g. ``output/chart.png``.
    Authenticate via ``?token=<jwt>`` query parameter.
    """
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
