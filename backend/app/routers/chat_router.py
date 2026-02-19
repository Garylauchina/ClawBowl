"""Chat proxy endpoint – forwards requests to user's OpenClaw container.

Includes conversation logging: every user message and AI response is
persisted to the chat_logs table for future memory/analytics.
"""

from __future__ import annotations

import json
import logging
import uuid
from collections.abc import AsyncGenerator
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.responses import StreamingResponse
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import get_current_user
from app.database import async_session, get_db
from app.models import ChatLog, User
from app.schemas import ChatRequest
from app.services.instance_manager import instance_manager
from app.services.proxy import cancel_user_stream, proxy_chat_request, proxy_chat_stream

logger = logging.getLogger("clawbowl.chat")

router = APIRouter(prefix="/api/v2", tags=["chat"])


# ── Conversation logging helpers ─────────────────────────────────────

def _extract_attachment_paths(messages: list[dict]) -> list[str]:
    """Extract file paths from multimodal message content."""
    paths: list[str] = []
    for m in messages:
        content = m.get("content")
        if isinstance(content, list):
            for part in content:
                if isinstance(part, dict) and part.get("type") == "file":
                    fn = part.get("filename", "")
                    if fn:
                        paths.append(fn)
    return paths


async def _save_log(
    user_id: str,
    event_id: str,
    role: str,
    content: str,
    *,
    thinking_text: str | None = None,
    attachment_paths: list[str] | None = None,
    tool_calls: list[dict[str, Any]] | None = None,
    log_status: str = "success",
    model: str | None = None,
) -> None:
    """Persist one chat log entry (fire-and-forget safe)."""
    try:
        async with async_session() as db:
            log = ChatLog(
                user_id=user_id,
                event_id=event_id,
                role=role,
                content=content,
                thinking_text=thinking_text or None,
                attachment_paths=json.dumps(attachment_paths, ensure_ascii=False) if attachment_paths else None,
                tool_calls=json.dumps(tool_calls, ensure_ascii=False) if tool_calls else None,
                status=log_status,
                model=model,
            )
            db.add(log)
            await db.commit()
    except Exception:
        logger.exception("Failed to save chat log (event=%s, role=%s)", event_id, role)


async def _logged_stream(
    generator: AsyncGenerator[str, None],
    user_id: str,
    event_id: str,
    model: str | None,
) -> AsyncGenerator[str, None]:
    """Wrap an SSE generator: transparently yield all chunks while
    accumulating the full response for persistence on stream completion."""
    content_parts: list[str] = []
    thinking_parts: list[str] = []
    tool_calls: list[dict[str, Any]] = []
    log_status = "success"

    try:
        async for chunk in generator:
            yield chunk

            # Parse SSE line for logging (best-effort, never block streaming)
            if not chunk.startswith("data: ") or chunk.startswith("data: [DONE]"):
                continue
            # Log file events for debugging
            if '"file"' in chunk:
                logger.info("SSE file event yielded: %s", chunk[:120])
            try:
                payload = json.loads(chunk[6:])
                choices = payload.get("choices") or []
                for choice in choices:
                    delta = choice.get("delta") or {}
                    if delta.get("filtered"):
                        log_status = "filtered"
                    if delta.get("content"):
                        content_parts.append(delta["content"])
                    if delta.get("thinking"):
                        thinking_parts.append(delta["thinking"])
                    if delta.get("tool_calls"):
                        for tc in delta["tool_calls"]:
                            func = tc.get("function") or {}
                            tool_calls.append({
                                "name": func.get("name", ""),
                                "arguments": func.get("arguments", ""),
                            })
                    fr = choice.get("finish_reason")
                    if fr and fr != "stop" and fr != "tool_calls":
                        log_status = "error"
            except (json.JSONDecodeError, KeyError, TypeError):
                pass
    except Exception:
        if log_status == "success":
            log_status = "interrupted"
        logger.warning("SSE stream interrupted for event %s", event_id)
    finally:
        # Always persist — even if client disconnected mid-stream
        full_content = "".join(content_parts)
        full_thinking = "".join(thinking_parts) or None
        if not full_content and log_status == "success":
            log_status = "error"

        await _save_log(
            user_id=user_id,
            event_id=event_id,
            role="assistant",
            content=full_content,
            thinking_text=full_thinking,
            tool_calls=tool_calls if tool_calls else None,
            log_status=log_status,
            model=model,
        )


# ── Endpoints ────────────────────────────────────────────────────────

@router.post("/chat/cancel")
async def cancel_chat(
    user: User = Depends(get_current_user),
):
    """Cancel the user's active SSE stream (fire-and-forget from frontend)."""
    cancelled = cancel_user_stream(user.id)
    return {"cancelled": cancelled}


@router.get("/chat/warmup")
async def warmup(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Lightweight endpoint to pre-warm the user's OpenClaw container.

    Called by the iOS SplashView so the container is ready when the
    user reaches the ChatView.  Returns immediately once the container
    is in the 'running' state.
    """
    instance = await instance_manager.ensure_running(user, db)
    return {"status": "warm", "port": instance.port}


@router.post("/chat")
async def chat(
    body: ChatRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Send a chat message through the user's dedicated OpenClaw instance."""
    instance = await instance_manager.ensure_running(user, db)

    messages = [{"role": m.role, "content": m.content} for m in body.messages]

    has_image = any(
        isinstance(m.get("content"), list) for m in messages
    )
    logger.info(
        "Chat request: user=%s, msgs=%d, has_image=%s, stream=%s",
        user.id, len(messages), has_image, body.stream,
    )

    # Generate event_id for this request-response pair
    event_id = str(uuid.uuid4())

    # Persist the user's latest message (last in the messages list)
    if messages:
        last_msg = messages[-1]
        user_content = last_msg.get("content", "")
        if isinstance(user_content, list):
            text_parts = [p.get("text", "") for p in user_content if isinstance(p, dict) and p.get("type") == "text"]
            user_text = " ".join(t for t in text_parts if t)
        else:
            user_text = str(user_content)

        att_paths = _extract_attachment_paths(messages[-1:])
        await _save_log(
            user_id=user.id,
            event_id=event_id,
            role="user",
            content=user_text,
            attachment_paths=att_paths if att_paths else None,
            model=body.model,
        )

    if body.stream:
        raw_generator = proxy_chat_stream(
            instance=instance,
            messages=messages,
            model=body.model,
        )
        logged_generator = _logged_stream(
            raw_generator,
            user_id=user.id,
            event_id=event_id,
            model=body.model,
        )
        return StreamingResponse(
            logged_generator,
            media_type="text/event-stream",
            headers={
                "Cache-Control": "no-cache",
                "X-Accel-Buffering": "no",
            },
        )
    else:
        result = await proxy_chat_request(
            instance=instance,
            messages=messages,
            model=body.model,
            stream=False,
        )
        # Persist non-streaming assistant response
        assistant_content = ""
        try:
            assistant_content = result["choices"][0]["message"]["content"]
        except (KeyError, IndexError, TypeError):
            pass
        await _save_log(
            user_id=user.id,
            event_id=event_id,
            role="assistant",
            content=assistant_content or "",
            model=body.model,
        )
        return result
