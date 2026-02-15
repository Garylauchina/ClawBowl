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
import uuid
from collections.abc import AsyncGenerator
from pathlib import Path

import httpx

from app.config import settings
from app.models import OpenClawInstance

logger = logging.getLogger(__name__)

_DEFAULT_MODEL = "zenmux/deepseek/deepseek-chat"

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


def _build_request_parts(
    instance: OpenClawInstance,
    messages: list[dict],
    model: str | None,
    stream: bool,
) -> tuple[str, dict[str, str], dict]:
    """Return (url, headers, body) for forwarding to OpenClaw gateway."""
    url = f"http://127.0.0.1:{instance.port}/v1/chat/completions"
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {instance.gateway_token}",
    }
    body: dict = {
        "model": model or _DEFAULT_MODEL,
        "messages": messages,
        "stream": stream,
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
    url, headers, body = _build_request_parts(instance, messages, model, stream)

    # Retry once on connection errors (gateway may still be warming up)
    last_exc: Exception | None = None
    for attempt in range(2):
        try:
            async with httpx.AsyncClient(timeout=_REQ_TIMEOUT) as client:
                resp = await client.post(url, json=body, headers=headers)
                resp.raise_for_status()
                return resp.json()
        except (httpx.ConnectError, httpx.ReadError) as exc:
            last_exc = exc
            if attempt == 0:
                logger.warning("Gateway connection failed, retrying in 5s: %s", exc)
                await asyncio.sleep(5)
    raise last_exc  # type: ignore[misc]


# ── Streaming request ─────────────────────────────────────────────────

def _make_thinking_chunk(message: str) -> str:
    """Build an SSE line with a 'thinking' delta for tool status display."""
    payload = json.dumps(
        {"choices": [{"delta": {"thinking": message}}]},
        ensure_ascii=False,
    )
    return f"data: {payload}\n\n"


async def proxy_chat_stream(
    instance: OpenClawInstance,
    messages: list[dict],
    model: str | None = None,
) -> AsyncGenerator[str, None]:
    """Forward a chat completion request and yield SSE lines in real time.

    - delta.content 行原样透传
    - delta.tool_calls 行转换为 delta.thinking 状态行
    - data: [DONE] 最终透传
    """
    messages = _preprocess_attachments(instance, messages)
    url, headers, body = _build_request_parts(instance, messages, model, stream=True)

    seen_tools: set[str] = set()  # avoid duplicate status for same tool call

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
                            yield "data: [DONE]\n\n"
                            return

                        if not line.startswith("data: "):
                            continue

                        # Parse the JSON payload
                        try:
                            chunk = json.loads(line[6:])
                        except json.JSONDecodeError:
                            # Forward unparseable lines as-is
                            yield line + "\n\n"
                            continue

                        choices = chunk.get("choices") or []
                        if not choices:
                            yield line + "\n\n"
                            continue

                        delta = choices[0].get("delta", {})

                        # ── Tool calls → inject thinking status ──
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
                                    yield _make_thinking_chunk(status)
                            # Don't forward raw tool_calls to client
                            continue

                        # ── Content text → forward as-is ──
                        if delta.get("content"):
                            yield line + "\n\n"
                            continue

                        # ── Other deltas (role, finish_reason, etc.) → forward ──
                        yield line + "\n\n"

            # If we reach here the stream completed successfully
            return

        except (httpx.ConnectError, httpx.ReadError) as exc:
            last_exc = exc
            if attempt == 0:
                logger.warning("Gateway stream connection failed, retrying in 5s: %s", exc)
                await asyncio.sleep(5)

    raise last_exc  # type: ignore[misc]
