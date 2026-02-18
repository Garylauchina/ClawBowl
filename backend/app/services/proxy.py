"""HTTP reverse proxy to forward chat requests to user's OpenClaw container.

附件处理策略（遵循 DESIGN.md）：
- 纯文本消息：直接转发给 OpenClaw agent
- 含附件消息（图片或文件）：
  1. 提取 base64 附件 → 保存到容器工作区 media/inbound/{filename}
  2. 向 OpenClaw 发送引用消息：[用户发送了文件: media/inbound/{filename}]
  3. OpenClaw 容器内自行调用 image/read 等工具处理

流式响应：
- proxy_chat_stream() 以 SSE 格式逐行返回 OpenClaw 的流式输出
- 检测 tool_calls → 注入 thinking 状态行，供客户端以浅色字体展示
"""

from __future__ import annotations

import asyncio
import base64
import json
import logging
import time
import uuid
from collections.abc import AsyncGenerator
from datetime import datetime, timezone
from pathlib import Path

import httpx

from app.config import settings
from app.models import OpenClawInstance

logger = logging.getLogger(__name__)

_DEFAULT_MODEL = "zenmux/deepseek/deepseek-chat"

# ── User-friendly error messages ─────────────────────────────────────
# Map technical errors to messages shown in the chat bubble.

_ERROR_MESSAGES: dict[str, str] = {
    "connect": "网络连接异常，正在重试...",
    "timeout": "AI 响应超时，请稍后重试",
    "read": "网络波动，数据读取中断",
    "server": "AI 服务暂时繁忙，请稍后再试",
    "unknown": "出了一点小问题，请稍后重试",
}


def _classify_error(exc: Exception) -> str:
    """Classify an exception into a user-friendly error category."""
    exc_str = str(exc).lower()
    if isinstance(exc, httpx.ConnectError):
        return "connect"
    if isinstance(exc, httpx.ConnectTimeout):
        return "timeout"
    if isinstance(exc, (httpx.ReadTimeout, httpx.ReadError)):
        return "read"
    if isinstance(exc, httpx.HTTPStatusError):
        code = exc.response.status_code if hasattr(exc, 'response') else 0
        if code >= 500:
            return "server"
        return "unknown"
    if "timeout" in exc_str or "timed out" in exc_str:
        return "timeout"
    if "connect" in exc_str or "connection" in exc_str:
        return "connect"
    return "unknown"


def _make_error_chunk(message: str) -> str:
    """Build an SSE line with an error message as content (shown in chat bubble)."""
    payload = json.dumps(
        {"choices": [{"delta": {"content": message}, "finish_reason": "stop"}]},
        ensure_ascii=False,
    )
    return f"data: {payload}\n\ndata: [DONE]\n\n"


_FILTERED_MESSAGE = "该内容暂时无法处理，已自动清理相关对话记录，请换个话题继续。"


def _make_filtered_chunk(message: str = _FILTERED_MESSAGE) -> str:
    """Build an SSE line indicating content was filtered by safety review."""
    payload = json.dumps(
        {"choices": [{"delta": {"content": message, "filtered": True}, "finish_reason": "stop"}]},
        ensure_ascii=False,
    )
    return f"data: {payload}\n\n"

# OpenClaw tool name → human-readable status (shown as "thinking" text)
_TOOL_STATUS_MAP: dict[str, str] = {
    "image": "正在分析图片...",
    "web_search": "正在搜索网页...",
    "web_fetch": "正在读取网页...",
    "read": "正在读取文件...",
    "write": "正在写入文件...",
    "edit": "正在编辑文件...",
    "exec": "正在执行命令...",
    "process": "正在处理任务...",
    "cron": "正在设置定时任务...",
    "memory": "正在检索记忆...",
}


def _extract_attachments(messages: list[dict]) -> tuple[list[dict], list[tuple[str, bytes]], bool]:
    """分析 messages，提取最后一条用户消息中的附件（图片 + 通用文件）。

    支持两种附件格式：
    - type="image_url"：OpenAI Vision 格式的 base64 图片
    - type="file"：自定义格式的通用文件 (filename, mime_type, data)

    Returns:
        (messages, [(filename, file_bytes), ...], has_attachments)
    """
    # 找到最后一条用户消息
    last_user_idx = -1
    for i in range(len(messages) - 1, -1, -1):
        if messages[i].get("role") == "user":
            last_user_idx = i
            break

    if last_user_idx < 0:
        return messages, [], False

    content = messages[last_user_idx].get("content")
    if not isinstance(content, list):
        return messages, [], False

    # 提取附件和文本
    attachments: list[tuple[str, bytes]] = []

    for part in content:
        if not isinstance(part, dict):
            continue

        part_type = part.get("type", "")

        # ── 图片 (OpenAI Vision 格式) ──
        if part_type == "image_url":
            url = part.get("image_url", {}).get("url", "")
            if url.startswith("data:"):
                try:
                    header, b64data = url.split(",", 1)
                    ext = "jpg"
                    if "png" in header:
                        ext = "png"
                    elif "gif" in header:
                        ext = "gif"
                    elif "webp" in header:
                        ext = "webp"
                    filename = f"{uuid.uuid4().hex[:12]}.{ext}"
                    file_bytes = base64.b64decode(b64data)
                    attachments.append((filename, file_bytes))
                except Exception:
                    logger.warning("Failed to decode base64 image")

        # ── 通用文件 ──
        elif part_type == "file":
            try:
                filename = part.get("filename", f"{uuid.uuid4().hex[:12]}.bin")
                b64data = part.get("data", "")
                file_bytes = base64.b64decode(b64data)
                attachments.append((filename, file_bytes))
            except Exception:
                logger.warning("Failed to decode base64 file: %s", part.get("filename"))

    if not attachments:
        return messages, [], False

    return messages, attachments, True


def _save_attachments_to_workspace(
    instance: OpenClawInstance, attachments: list[tuple[str, bytes]]
) -> list[str]:
    """将附件保存到容器工作区的 media/inbound/ 目录。

    Returns:
        保存后的相对路径列表，如 ['media/inbound/report.pdf']
    """
    workspace_dir = Path(instance.data_path) / "workspace"
    inbound_dir = workspace_dir / "media" / "inbound"
    inbound_dir.mkdir(parents=True, exist_ok=True)

    saved_paths: list[str] = []
    for filename, file_bytes in attachments:
        # 确保文件名安全（去掉路径分隔符）
        safe_name = filename.replace("/", "_").replace("\\", "_")
        file_path = inbound_dir / safe_name
        file_path.write_bytes(file_bytes)
        relative_path = f"media/inbound/{safe_name}"
        saved_paths.append(relative_path)
        logger.info("Saved attachment to workspace: %s (%d bytes)", relative_path, len(file_bytes))

    return saved_paths


def _rebuild_messages_with_file_refs(
    messages: list[dict], file_paths: list[str]
) -> list[dict]:
    """将最后一条含附件的用户消息替换为文件引用消息。"""
    new_messages: list[dict] = []
    replaced = False

    for msg in messages:
        if msg.get("role") != "user" or replaced:
            new_messages.append(msg)
            continue

        content = msg.get("content")
        if not isinstance(content, list):
            new_messages.append(msg)
            continue

        # 检查是否含附件
        has_attachment = any(
            isinstance(p, dict) and p.get("type") in ("image_url", "file")
            for p in content
        )
        if not has_attachment:
            new_messages.append(msg)
            continue

        # 提取用户文本
        texts = [
            p.get("text", "").strip()
            for p in content
            if isinstance(p, dict) and p.get("type") == "text"
        ]
        user_text = "\n".join(t for t in texts if t)

        # 构建引用消息
        file_refs = "\n".join(
            f"[用户发送了文件: {path}]" for path in file_paths
        )
        combined = file_refs
        if user_text:
            combined += f"\n\n{user_text}"

        new_messages.append({"role": msg["role"], "content": combined})
        replaced = True

    return new_messages


def _preprocess_attachments(
    instance: OpenClawInstance, messages: list[dict]
) -> list[dict]:
    """Handle multimodal messages: save attachments to workspace, replace with file refs.

    统一处理图片和文件附件，供 proxy_chat_request 和 proxy_chat_stream 复用。
    """
    messages, attachments, has_attachments = _extract_attachments(messages)
    if not has_attachments:
        return messages

    # 1. 保存附件到容器工作区
    file_paths = _save_attachments_to_workspace(instance, attachments)
    logger.info("Saved %d attachment(s) to workspace: %s", len(file_paths), file_paths)

    # 2. 重建消息（替换附件为文件引用）
    return _rebuild_messages_with_file_refs(messages, file_paths)


# ── Shared constants ──────────────────────────────────────────────────

_REQ_TIMEOUT = httpx.Timeout(connect=30, read=300, write=30, pool=30)


def _inject_date_context(messages: list[dict]) -> list[dict]:
    """Inject current date/time context so the Agent has accurate temporal
    awareness.  Two-pronged approach:
    1. Prepend a system message (for agents that honor system prompts)
    2. Append a short reminder to the last user message (hard to ignore)
    """
    now = datetime.now(timezone.utc)
    date_str = now.strftime("%Y-%m-%d %H:%M UTC")
    weekday = now.strftime("%A")

    system_msg = {
        "role": "system",
        "content": (
            f"IMPORTANT: Today is {date_str} ({weekday}), year {now.year}. "
            f"Always use {now.year} as the current year for any time calculations."
        ),
    }

    result = [system_msg] + list(messages)

    # Also tag the last user message with a date hint
    for i in range(len(result) - 1, -1, -1):
        if result[i].get("role") == "user":
            content = result[i].get("content", "")
            if isinstance(content, str) and str(now.year) not in content:
                result[i] = dict(result[i])
                result[i]["content"] = (
                    f"{content}\n\n[System note: current date is {date_str}, year {now.year}]"
                )
            break

    return result


def _build_request_parts(
    instance: OpenClawInstance,
    messages: list[dict],
    model: str | None,
    stream: bool,
) -> tuple[str, dict[str, str], dict]:
    """Return (url, headers, body) for forwarding to OpenClaw gateway.

    关键设计：
    - 使用 instance.user_id 作为 OpenAI `user` 字段 → OpenClaw 网关据此
      派生稳定 session key，实现跨请求的持久会话（对话历史、记忆管理等）。
    - 同时设置 x-openclaw-session-key 以获得更精确的会话路由控制。
    """
    url = f"http://127.0.0.1:{instance.port}/v1/chat/completions"
    # Stable session key = "clawbowl-{user_id}" → Gateway 根据此值复用 session
    session_key = f"clawbowl-{instance.user_id}"
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {instance.gateway_token}",
        "x-openclaw-session-key": session_key,
    }
    body: dict = {
        "model": model or _DEFAULT_MODEL,
        "messages": messages,
        "stream": stream,
        "user": instance.user_id,  # OpenClaw 据此派生持久 session
    }
    return url, headers, body


# ── Non-streaming request (kept for backward compat) ─────────────────

async def proxy_chat_request(
    instance: OpenClawInstance,
    messages: list[dict],
    model: str | None = None,
    stream: bool = False,
) -> dict:
    """Forward a chat completion request to the user's OpenClaw gateway (non-streaming)."""
    messages = _preprocess_attachments(instance, messages)
    messages = _inject_date_context(messages)
    url, headers, body = _build_request_parts(instance, messages, model, stream)

    # Retry once on connection errors (gateway may still be warming up)
    last_exc: Exception | None = None
    for attempt in range(2):
        try:
            async with httpx.AsyncClient(timeout=_REQ_TIMEOUT) as client:
                resp = await client.post(url, json=body, headers=headers)
                resp.raise_for_status()
                return resp.json()
        except Exception as exc:
            last_exc = exc
            error_cat = _classify_error(exc)
            if attempt == 0:
                logger.warning("Gateway connection failed (category=%s), retrying in 3s: %s", error_cat, exc)
                await asyncio.sleep(3)

    # Return a structured error response instead of raising
    error_cat = _classify_error(last_exc) if last_exc else "unknown"
    friendly_msg = _ERROR_MESSAGES.get(error_cat, _ERROR_MESSAGES["unknown"])
    logger.error("Returning friendly error (non-stream): %s (original: %s)", friendly_msg, last_exc)
    return {
        "choices": [{
            "message": {"role": "assistant", "content": friendly_msg},
            "finish_reason": "stop",
        }]
    }


# ── Streaming request ─────────────────────────────────────────────────

def _make_thinking_chunk(message: str) -> str:
    """Build an SSE line with a 'thinking' delta for real-time status display."""
    payload = json.dumps(
        {"choices": [{"delta": {"thinking": message}}]},
        ensure_ascii=False,
    )
    return f"data: {payload}\n\n"


def _make_content_chunk(text: str) -> str:
    """Build an SSE line with a 'content' delta."""
    payload = json.dumps(
        {"choices": [{"delta": {"content": text}}]},
        ensure_ascii=False,
    )
    return f"data: {payload}\n\n"


# ── Workspace snapshot / diff for file detection ─────────────────────

# Directories excluded from workspace diff (agent internal files)
_WS_EXCLUDE_DIRS = {
    "media/inbound", ".openclaw", ".git", "__pycache__", "memory", "skills",
    "excel_env", "venv", "env", ".venv", "node_modules", "lib",
}
_WS_EXCLUDE_PREFIXES = (".", "_")


def _snapshot_workspace(workspace_dir: Path) -> dict[str, tuple[int, float]]:
    """Take a snapshot of workspace files: {relative_path: (size, mtime)}.

    Uses os.walk with directory pruning for performance — skips excluded dirs
    entirely without traversing their contents.
    """
    import os

    snapshot: dict[str, tuple[int, float]] = {}
    if not workspace_dir.is_dir():
        return snapshot
    ws_str = str(workspace_dir)
    try:
        for dirpath, dirnames, filenames in os.walk(workspace_dir):
            rel_dir = os.path.relpath(dirpath, ws_str)
            # Prune excluded subdirectories in-place (prevents os.walk from descending)
            dirnames[:] = [
                d for d in dirnames
                if d not in _WS_EXCLUDE_DIRS
                and not d.startswith(".")
                and not d.startswith("_")
            ]
            for fname in filenames:
                if fname.startswith("."):
                    continue
                rel_path = fname if rel_dir == "." else f"{rel_dir}/{fname}"
                full = os.path.join(dirpath, fname)
                try:
                    st = os.stat(full)
                    snapshot[rel_path] = (st.st_size, st.st_mtime)
                except OSError:
                    pass
    except OSError:
        logger.warning("Failed to snapshot workspace: %s", workspace_dir)
    return snapshot


def _diff_workspace(
    before: dict[str, tuple[int, float]],
    after: dict[str, tuple[int, float]],
) -> list[dict]:
    """Compare two snapshots, return list of new/modified file info dicts.

    Returns list of: {"name": "chart.png", "path": "output/chart.png", "size": 12345, "type": "image/png"}
    """
    import mimetypes

    new_files: list[dict] = []
    for rel_path, (size, mtime) in after.items():
        prev = before.get(rel_path)
        if prev is None or prev != (size, mtime):
            # New or modified file
            name = Path(rel_path).name
            mime_type, _ = mimetypes.guess_type(name)
            if mime_type is None:
                mime_type = "application/octet-stream"
            new_files.append({
                "name": name,
                "path": rel_path,
                "size": size,
                "type": mime_type,
            })
    return new_files


def _make_file_chunk(file_info: dict) -> str:
    """Build an SSE line with a 'file' delta for file detection."""
    payload = json.dumps(
        {"choices": [{"delta": {"file": file_info}}]},
        ensure_ascii=False,
    )
    return f"data: {payload}\n\n"


_TURN_GAP_SECONDS = 3.0
"""时间间隔阈值（秒）：content chunk 之间超过此间隔视为新的 agent 轮次。

OpenClaw 网关在工具执行期间会暂停 SSE 流（几秒到几分钟），
而 LLM 文本生成是毫秒级连续输出。利用这个时间差来检测轮次边界，
从而将最后一个"快速连发"段识别为最终结果。"""


async def proxy_chat_stream(
    instance: OpenClawInstance,
    messages: list[dict],
    model: str | None = None,
) -> AsyncGenerator[str, None]:
    """Forward a chat completion request and yield SSE lines in real time.

    核心策略：
    1. 所有 delta.content → 作为 thinking 实时发送（浅色字体）
    2. 同时缓冲内容，用时间间隔检测轮次边界
    3. content chunk 间隔 > 3 秒 → 视为新轮次，清空缓冲 + 在 thinking 中插入换行
    4. [DONE] / finish_reason:"stop" → 将最后一轮缓冲作为 content 发送（正式回答）
    5. 客户端收到 content → 清除 thinking，只保留最终结果
    """
    messages = _preprocess_attachments(instance, messages)
    messages = _inject_date_context(messages)
    url, headers, body = _build_request_parts(instance, messages, model, stream=True)

    # Workspace snapshot before the stream (for file detection at end)
    workspace_dir = Path(instance.data_path) / "workspace"
    ws_before = _snapshot_workspace(workspace_dir)

    seen_tools: set[str] = set()
    content_buf: list[str] = []   # buffer content for current turn
    thinking_emitted = False      # any thinking sent yet?
    last_content_ts = 0.0         # monotonic time of last content chunk
    turn_count = 1                # current turn number
    chunk_count = 0               # total chunks (for logging)
    # ── Thinking 节流：攒够一定字符再发，减少 SSE 事件数 ──
    thinking_batch: list[str] = []
    thinking_batch_chars = 0
    _THINKING_BATCH_CHARS = 80    # 每攒够 80 字符发一次 thinking

    last_exc: Exception | None = None
    for attempt in range(2):
        try:
            async with httpx.AsyncClient(timeout=_REQ_TIMEOUT) as client:
                async with client.stream("POST", url, json=body, headers=headers) as resp:
                    resp.raise_for_status()
                    async for raw_line in resp.aiter_lines():
                        line = raw_line.strip()
                        if not line:
                            continue

                        # data: [DONE]
                        if line == "data: [DONE]":
                            # Flush any pending thinking batch
                            if thinking_batch:
                                yield _make_thinking_chunk(
                                    "".join(thinking_batch)
                                )
                                thinking_batch.clear()
                            if chunk_count == 0:
                                msg_count = len(messages)
                                if msg_count > 4:
                                    # Substantial history → likely content safety filter
                                    logger.warning(
                                        "Empty SSE response (0 chunks, %d msgs) — content safety filter",
                                        msg_count,
                                    )
                                    yield _make_filtered_chunk()
                                else:
                                    # Short conversation → likely instance startup issue
                                    logger.warning(
                                        "Empty SSE response (0 chunks, %d msgs) — instance may not be ready",
                                        msg_count,
                                    )
                                    yield _make_content_chunk("AI 暂时无法响应，请稍后重试")
                            # Emit last turn's buffer as real content
                            elif content_buf:
                                final = "".join(content_buf).strip()
                                if final:
                                    yield _make_content_chunk(final)

                            # ── File detection: workspace diff ──
                            ws_after = _snapshot_workspace(workspace_dir)
                            new_files = _diff_workspace(ws_before, ws_after)
                            if new_files:
                                logger.info(
                                    "Workspace diff: %d new/modified file(s): %s",
                                    len(new_files),
                                    ", ".join(f"{f['name']}({f['size']}b)" for f in new_files),
                                )
                                for finfo in new_files:
                                    yield _make_file_chunk(finfo)

                            yield "data: [DONE]\n\n"
                            logger.info(
                                "SSE done: %d chunks, %d turns, %d tools, %d files",
                                chunk_count, turn_count, len(seen_tools),
                                len(new_files) if new_files else 0,
                            )
                            return

                        if not line.startswith("data: "):
                            continue

                        try:
                            chunk = json.loads(line[6:])
                        except json.JSONDecodeError:
                            yield line + "\n\n"
                            continue

                        choices = chunk.get("choices") or []
                        if not choices:
                            yield line + "\n\n"
                            continue

                        choice = choices[0]
                        delta = choice.get("delta", {})
                        finish_reason = choice.get("finish_reason")
                        chunk_count += 1

                        # Sampled logging
                        if chunk_count <= 3 or finish_reason:
                            logger.info(
                                "SSE #%d: finish=%s turn=%d",
                                chunk_count, finish_reason, turn_count,
                            )

                        # ── Tool calls → emit thinking status ──
                        tool_calls = delta.get("tool_calls")
                        if tool_calls:
                            for tc in tool_calls:
                                fn = tc.get("function", {})
                                tool_name = fn.get("name", "")
                                if tool_name and tool_name not in seen_tools:
                                    seen_tools.add(tool_name)
                                    status = _TOOL_STATUS_MAP.get(
                                        tool_name, f"正在执行 {tool_name}..."
                                    )
                                    prefix = "\n" if thinking_emitted else ""
                                    yield _make_thinking_chunk(prefix + status + "\n")
                                    thinking_emitted = True

                        # ── Content text ──
                        content_text = delta.get("content")
                        if content_text:
                            now = time.monotonic()

                            # 检测轮次边界：时间间隔 > 阈值 → 新轮次
                            if last_content_ts > 0:
                                gap = now - last_content_ts
                                if gap > _TURN_GAP_SECONDS:
                                    # 新轮次：先 flush 积攒的 thinking
                                    if thinking_batch:
                                        yield _make_thinking_chunk(
                                            "".join(thinking_batch)
                                        )
                                        thinking_batch.clear()
                                        thinking_batch_chars = 0
                                    # 清空缓冲 + 在 thinking 中插入分隔
                                    content_buf.clear()
                                    turn_count += 1
                                    if thinking_emitted:
                                        yield _make_thinking_chunk("\n\n")
                                    logger.info(
                                        "Turn boundary: gap=%.1fs → turn %d",
                                        gap, turn_count,
                                    )

                            last_content_ts = now
                            content_buf.append(content_text)

                            # 节流 thinking：攒够字符再发（减少 SSE 事件 ~10x）
                            thinking_batch.append(content_text)
                            thinking_batch_chars += len(content_text)
                            if thinking_batch_chars >= _THINKING_BATCH_CHARS:
                                yield _make_thinking_chunk(
                                    "".join(thinking_batch)
                                )
                                thinking_batch.clear()
                                thinking_batch_chars = 0
                                thinking_emitted = True

                        # ── Finish reason (protocol-level markers) ──
                        if finish_reason == "tool_calls":
                            if thinking_batch:
                                yield _make_thinking_chunk(
                                    "".join(thinking_batch)
                                )
                                thinking_batch.clear()
                                thinking_batch_chars = 0
                            content_buf.clear()
                            turn_count += 1
                            if thinking_emitted:
                                yield _make_thinking_chunk("\n\n")
                            logger.info("Turn ended (tool_calls) → turn %d", turn_count)
                        elif finish_reason == "stop":
                            if thinking_batch:
                                yield _make_thinking_chunk(
                                    "".join(thinking_batch)
                                )
                                thinking_batch.clear()
                                thinking_batch_chars = 0
                            if content_buf:
                                final = "".join(content_buf).strip()
                                if final:
                                    yield _make_content_chunk(final)
                                content_buf.clear()
                                logger.info("Final turn (stop), content emitted")

            return

        except Exception as exc:
            last_exc = exc
            error_cat = _classify_error(exc)
            if attempt == 0:
                logger.warning(
                    "Gateway stream failed (attempt 1, category=%s): %s",
                    error_cat, exc,
                )
                await asyncio.sleep(3)
            else:
                logger.error(
                    "Gateway stream failed (final, category=%s): %s",
                    error_cat, exc, exc_info=True,
                )

    # All retries exhausted — send a friendly error message in the SSE stream
    # instead of raising an exception (which would cause a raw HTTP error).
    error_cat = _classify_error(last_exc) if last_exc else "unknown"
    friendly_msg = _ERROR_MESSAGES.get(error_cat, _ERROR_MESSAGES["unknown"])
    logger.error("Returning friendly error to client: %s (original: %s)", friendly_msg, last_exc)
    yield _make_error_chunk(friendly_msg)
