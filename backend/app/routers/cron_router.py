"""Cron job management endpoints - proxy to OpenClaw gateway cron tool."""

from __future__ import annotations

import logging

import httpx
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import get_current_user
from app.database import get_db
from app.models import User
from app.services.instance_manager import instance_manager

logger = logging.getLogger("clawbowl.cron")

router = APIRouter(prefix="/api/v2/cron", tags=["cron"])

_TIMEOUT = httpx.Timeout(connect=10, read=30, write=10, pool=10)


async def _gateway_cron_action(
    inst, action: str, extra: dict | None = None,
) -> dict:
    """Send a cron tool action to the OpenClaw gateway via chat completions."""
    url = f"http://127.0.0.1:{inst.port}/v1/chat/completions"
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {inst.gateway_token}",
    }

    import json
    args = {"action": action}
    if extra:
        args.update(extra)

    body = {
        "model": "zenmux/deepseek/deepseek-chat",
        "messages": [
            {
                "role": "user",
                "content": f"Use the cron tool with action={action}. "
                           f"Args: {json.dumps(args)}",
            }
        ],
        "stream": False,
        "user": inst.user_id,
    }

    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        resp = await client.post(url, json=body, headers=headers)
        resp.raise_for_status()
        return resp.json()


@router.get("/jobs")
async def list_jobs(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """List all cron jobs for the current user's OpenClaw instance."""
    inst = await instance_manager.get_instance(user.id, db)
    if inst is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "No instance found")

    try:
        result = await _gateway_cron_action(inst, "list")
        content = result.get("choices", [{}])[0].get("message", {}).get("content", "")
        return {"jobs": content}
    except httpx.ConnectError:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "Instance not ready")
    except Exception as exc:
        logger.exception("Cron list failed for user %s", user.id)
        raise HTTPException(status.HTTP_500_INTERNAL_SERVER_ERROR, str(exc)) from exc


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

    try:
        result = await _gateway_cron_action(inst, "remove", {"id": job_id})
        content = result.get("choices", [{}])[0].get("message", {}).get("content", "")
        return {"result": content}
    except httpx.ConnectError:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "Instance not ready")
    except Exception as exc:
        logger.exception("Cron delete failed for user %s, job %s", user.id, job_id)
        raise HTTPException(status.HTTP_500_INTERNAL_SERVER_ERROR, str(exc)) from exc
