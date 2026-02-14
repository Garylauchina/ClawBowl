"""HTTP reverse proxy to forward chat requests to user's OpenClaw container."""

from __future__ import annotations

import httpx

from app.models import OpenClawInstance


async def proxy_chat_request(
    instance: OpenClawInstance,
    messages: list[dict],
    model: str | None = None,
    stream: bool = False,
) -> dict:
    """Forward a chat completion request to the user's OpenClaw gateway.

    Returns the parsed JSON response from OpenClaw.
    """
    url = f"http://127.0.0.1:{instance.port}/v1/chat/completions"
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {instance.gateway_token}",
    }
    body: dict = {
        "model": model or "zenmux/deepseek/deepseek-chat",
        "messages": messages,
        "stream": stream,
    }

    async with httpx.AsyncClient(timeout=120) as client:
        resp = await client.post(url, json=body, headers=headers)
        resp.raise_for_status()
        return resp.json()
