"""LLM Proxy – 在 OpenClaw 和 ZenMux 之间注入 AutoRouter 配置。

OpenClaw 容器将此端点配置为 LLM provider 的 baseUrl，
使用 gateway_token 作为 API key。
本代理：
  1. 通过 gateway_token 识别用户
  2. 根据用户订阅层级注入 model_routing_config
  3. 替换为真正的 ZenMux API key
  4. 转发请求到 ZenMux 并返回响应
"""

import logging

import httpx
from fastapi import APIRouter, Request, HTTPException
from sqlalchemy import select

from app.config import settings
from app.database import async_session
from app.models import OpenClawInstance, User
from app.subscriptions.tier import get_tier

logger = logging.getLogger(__name__)
router = APIRouter(tags=["llm-proxy"])

ZENMUX_BASE = settings.zenmux_base_url.rstrip("/")


@router.api_route("/llm/{path:path}", methods=["GET", "POST"])
async def llm_proxy(path: str, request: Request):
    """透明代理：OpenClaw → 本端点 → ZenMux。

    OpenClaw 的 baseUrl 设为 http://172.17.0.1:8000/llm，
    请求如 /llm/chat/completions 会匹配此路由。
    本代理注入 model_routing_config 后转发到 ZenMux /v1/chat/completions。
    """
    # 1. 从 Authorization header 提取 gateway_token
    auth_header = request.headers.get("Authorization", "")
    if not auth_header.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token")
    gateway_token = auth_header.removeprefix("Bearer ").strip()

    # 2. 通过 gateway_token 查找用户和层级
    async with async_session() as db:
        result = await db.execute(
            select(OpenClawInstance, User)
            .join(User, OpenClawInstance.user_id == User.id)
            .where(OpenClawInstance.gateway_token == gateway_token)
        )
        row = result.first()

    if not row:
        raise HTTPException(status_code=401, detail="Invalid gateway token")

    instance, user = row
    tier = get_tier(user.subscription_tier)

    # 3. 读取请求体
    body_bytes = await request.body()

    # 4. 如果是 chat/completions 且 model 是 zenmux/auto，注入 model_routing_config
    import json
    content_type = request.headers.get("content-type", "")
    if "json" in content_type and body_bytes:
        try:
            body = json.loads(body_bytes)
            if body.get("model") == "zenmux/auto":
                body["model_routing_config"] = tier.get_model_routing_config()
                logger.info(
                    "Injected AutoRouter config for user %s (tier=%s, preference=%s, models=%s)",
                    user.id, tier.name, tier.routing_preference,
                    tier.routing_models,
                )
            body_bytes = json.dumps(body).encode()
        except (json.JSONDecodeError, KeyError):
            pass  # 非 JSON 请求，原样转发

    # 5. 转发到 ZenMux（替换 API key）
    #    ZENMUX_BASE 已包含 /api/v1，path 是 chat/completions
    target_url = f"{ZENMUX_BASE}/{path}"
    forward_headers = {
        "Content-Type": content_type or "application/json",
        "Authorization": f"Bearer {settings.zenmux_api_key}",
    }

    async with httpx.AsyncClient(timeout=120) as client:
        resp = await client.request(
            method=request.method,
            url=target_url,
            content=body_bytes,
            headers=forward_headers,
        )

    logger.info("ZenMux response: status=%d, body_len=%d, url=%s", resp.status_code, len(resp.content), target_url)
    if resp.status_code != 200:
        logger.warning("ZenMux error body: %s", resp.text[:500])

    from fastapi.responses import Response
    return Response(content=resp.content, status_code=resp.status_code, media_type="application/json")
