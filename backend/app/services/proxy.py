"""HTTP reverse proxy to forward chat requests to user's OpenClaw container."""

from __future__ import annotations

import httpx

from app.models import OpenClawInstance

# 支持多模态的模型（当消息包含图片时自动切换）
_VISION_MODEL = "zenmux/z-ai/glm-4.6v-flash-free"
_DEFAULT_MODEL = "zenmux/deepseek/deepseek-chat"


def _has_image(messages: list[dict]) -> bool:
    """检测消息列表中是否包含图片内容。"""
    for msg in messages:
        content = msg.get("content")
        if isinstance(content, list):
            for part in content:
                if isinstance(part, dict) and part.get("type") == "image_url":
                    return True
    return False


async def proxy_chat_request(
    instance: OpenClawInstance,
    messages: list[dict],
    model: str | None = None,
    stream: bool = False,
) -> dict:
    """Forward a chat completion request to the user's OpenClaw gateway.

    自动检测多模态内容并切换到支持图片的模型。
    Returns the parsed JSON response from OpenClaw.
    """
    # 自动选择模型：有图片 → vision model，纯文本 → default
    if model:
        effective_model = model
    elif _has_image(messages):
        effective_model = _VISION_MODEL
    else:
        effective_model = _DEFAULT_MODEL

    url = f"http://127.0.0.1:{instance.port}/v1/chat/completions"
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {instance.gateway_token}",
    }
    body: dict = {
        "model": effective_model,
        "messages": messages,
        "stream": stream,
    }

    async with httpx.AsyncClient(timeout=120) as client:
        resp = await client.post(url, json=body, headers=headers)
        resp.raise_for_status()
        return resp.json()
