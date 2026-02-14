"""HTTP reverse proxy to forward chat requests to user's OpenClaw container.

图片处理策略：
- 纯文本消息：直接转发给 OpenClaw agent
- 含图片消息：Orchestrator 先调用 ZenMux 视觉模型分析图片，
  将图片描述+用户问题组合为纯文本，再转发给 OpenClaw
"""

from __future__ import annotations

import logging

import httpx

from app.config import settings
from app.models import OpenClawInstance

logger = logging.getLogger(__name__)

_DEFAULT_MODEL = "zenmux/deepseek/deepseek-chat"
_VISION_MODEL = "z-ai/glm-4.6v-flash-free"  # 用于 ZenMux 直连


def _extract_image_parts(messages: list[dict]) -> tuple[list[dict], bool]:
    """分析 messages，提取图片部分并判断是否含图片。

    返回 (image_content_parts, has_image)，
    其中 image_content_parts 是最后一条用户消息中的所有 content parts。
    """
    for msg in reversed(messages):
        if msg.get("role") != "user":
            continue
        content = msg.get("content")
        if isinstance(content, list):
            for part in content:
                if isinstance(part, dict) and part.get("type") == "image_url":
                    return content, True
        break
    return [], False


async def _describe_image(content_parts: list) -> str:
    """调用 ZenMux 视觉模型分析图片，返回描述文本。

    content_parts 是 OpenAI Vision 格式的内容数组。
    """
    # 组合用户文本和图片
    user_text_parts = []
    image_parts = []
    for part in content_parts:
        if not isinstance(part, dict):
            continue
        if part.get("type") == "text":
            user_text_parts.append(part.get("text", ""))
        elif part.get("type") == "image_url":
            image_parts.append(part)

    user_text = "\n".join(user_text_parts).strip()

    # 构建发给视觉模型的 prompt
    vision_content: list[dict] = []
    for img in image_parts:
        vision_content.append(img)
    vision_content.append({
        "type": "text",
        "text": (
            "请详细描述这张图片的内容，包括颜色、物体、文字、场景等所有可见信息。"
            "用中文回答，尽量详细。"
        ),
    })

    url = f"{settings.zenmux_base_url}/chat/completions"
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {settings.zenmux_api_key}",
    }
    body = {
        "model": _VISION_MODEL,
        "messages": [{"role": "user", "content": vision_content}],
        "stream": False,
        "max_tokens": 1024,
    }

    try:
        async with httpx.AsyncClient(timeout=60) as client:
            resp = await client.post(url, json=body, headers=headers)
            resp.raise_for_status()
            data = resp.json()
            description = (
                data.get("choices", [{}])[0]
                .get("message", {})
                .get("content", "")
            )
            logger.info("Image described by vision model: %s chars", len(description))
            return description
    except Exception:
        logger.exception("Failed to describe image via ZenMux vision model")
        return "(图片分析失败，请重试)"


def _rebuild_messages_with_description(
    messages: list[dict], description: str
) -> list[dict]:
    """将最后一条含图片的用户消息替换为：图片描述 + 用户原始问题。"""
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

        # 检查是否含图片
        has_img = any(
            isinstance(p, dict) and p.get("type") == "image_url"
            for p in content
        )
        if not has_img:
            new_messages.append(msg)
            continue

        # 提取用户文本
        user_texts = [
            p.get("text", "")
            for p in content
            if isinstance(p, dict) and p.get("type") == "text"
        ]
        user_text = "\n".join(user_texts).strip()

        # 组合消息
        combined = f"[用户发送了一张图片，以下是图片内容描述]\n{description}"
        if user_text:
            combined += f"\n\n[用户的问题]\n{user_text}"

        new_messages.append({"role": msg["role"], "content": combined})
        replaced = True

    return new_messages


async def proxy_chat_request(
    instance: OpenClawInstance,
    messages: list[dict],
    model: str | None = None,
    stream: bool = False,
) -> dict:
    """Forward a chat completion request to the user's OpenClaw gateway.

    含图片时先用视觉模型预处理，再以纯文本转发给 OpenClaw。
    """
    content_parts, has_image = _extract_image_parts(messages)

    if has_image:
        logger.info("Image detected, calling vision model for description")
        description = await _describe_image(content_parts)
        messages = _rebuild_messages_with_description(messages, description)

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

    async with httpx.AsyncClient(timeout=120) as client:
        resp = await client.post(url, json=body, headers=headers)
        resp.raise_for_status()
        return resp.json()
