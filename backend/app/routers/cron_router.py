"""Cron job management endpoints - read directly from OpenClaw cron config."""

from __future__ import annotations

import json
import logging
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import get_current_user
from app.database import get_db
from app.models import User
from app.services.instance_manager import instance_manager

logger = logging.getLogger("clawbowl.cron")

router = APIRouter(prefix="/api/v2/cron", tags=["cron"])


def _jobs_json_path(config_path: str) -> Path:
    return Path(config_path) / "cron" / "jobs.json"


def _read_jobs(config_path: str) -> list[dict]:
    path = _jobs_json_path(config_path)
    if not path.exists():
        return []
    try:
        data = json.loads(path.read_text())
        return data.get("jobs", [])
    except (json.JSONDecodeError, OSError) as exc:
        logger.warning("Failed to read cron jobs from %s: %s", path, exc)
        return []


@router.post("/jobs")
async def list_jobs(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """List all cron jobs for the current user's OpenClaw instance."""
    inst = await instance_manager.get_instance(user.id, db)
    if inst is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "No instance found")

    jobs = _read_jobs(inst.config_path)
    return {"jobs": jobs}


@router.delete("/jobs/{job_id}")
async def delete_job(
    job_id: str,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Remove a cron job by ID."""
    inst = await instance_manager.get_instance(user.id, db)
    if inst is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "No instance found")

    path = _jobs_json_path(inst.config_path)
    if not path.exists():
        raise HTTPException(status.HTTP_404_NOT_FOUND, "No cron config found")

    try:
        data = json.loads(path.read_text())
    except (json.JSONDecodeError, OSError) as exc:
        raise HTTPException(status.HTTP_500_INTERNAL_SERVER_ERROR, f"Read error: {exc}") from exc

    original_count = len(data.get("jobs", []))
    data["jobs"] = [j for j in data.get("jobs", []) if j.get("id") != job_id]

    if len(data["jobs"]) == original_count:
        raise HTTPException(status.HTTP_404_NOT_FOUND, f"Job {job_id} not found")

    try:
        path.write_text(json.dumps(data, indent=2, ensure_ascii=False))
    except OSError as exc:
        raise HTTPException(status.HTTP_500_INTERNAL_SERVER_ERROR, f"Write error: {exc}") from exc

    return {"result": "deleted", "job_id": job_id}
