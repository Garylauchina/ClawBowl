"""Subscription tier definitions and their resource limits.

所有层级统一使用 ZenMux AutoRouter (zenmux/auto)，
通过 model_routing_config 控制候选模型池和路由策略。

Tier 设计:
  - free:    AutoRouter + 国内免费/极低价 LLM，preference=price
  - pro:     AutoRouter + 国内高级 LLM，preference=balanced
  - premium: AutoRouter + 全部高级 LLM，preference=performance
"""

from dataclasses import dataclass, field


@dataclass(frozen=True)
class TierConfig:
    """Resource limits and model routing config for a subscription tier."""

    name: str
    template: str  # 配置模板: "free" or "premium"
    primary_model: str  # OpenClaw primary model reference

    # AutoRouter 配置 — 注入到发往 OpenClaw 的请求中
    routing_models: tuple[str, ...]  # 候选模型池
    routing_preference: str  # "price" / "balanced" / "performance"

    max_tokens: int
    daily_message_limit: int | None  # None = unlimited
    container_memory: str
    container_cpus: float

    def get_model_routing_config(self) -> dict:
        """生成注入到请求体中的 model_routing_config。"""
        return {
            "available_models": list(self.routing_models),
            "preference": self.routing_preference,
        }


# ── 免费用户：国内免费/极低价 LLM ──────────────────────────────────────
_FREE_MODELS = (
    "xiaomi/mimo-v2-flash",          # 小米 MiMo V2 Flash — 免费，262K，媲美 Claude Sonnet 4.5
    "deepseek/deepseek-chat",        # DeepSeek V3.2 — $0.28/$0.42/M，128K
    "z-ai/glm-4.6v-flash-free",     # 智谱 GLM 4.6V Flash — 免费，200K，多模态
)

# ── 付费用户：国内高级 LLM ─────────────────────────────────────────────
_PRO_MODELS = (
    "deepseek/deepseek-reasoner",    # DeepSeek V3.2 深度思考 — $0.28/$0.42/M
    "z-ai/glm-4.7",                 # 智谱 GLM 4.7 旗舰 — $0.28-0.57/$1.14-2.27/M
    "moonshotai/kimi-k2-thinking",   # Kimi K2 深度推理 — $0.60/$2.50/M
    "volcengine/doubao-seed-1.8",    # 字节豆包 Seed 1.8 — $0.11-0.34/$0.28-3.41/M
    "baidu/ernie-5.0-thinking-preview",  # 百度文心 5.0 — $0.84-1.41/$3.37-5.62/M
)


TIERS: dict[str, TierConfig] = {
    "free": TierConfig(
        name="free",
        template="free",
        primary_model="zenmux/zenmux/auto",
        routing_models=_FREE_MODELS,
        routing_preference="price",
        max_tokens=4096,
        daily_message_limit=50,
        container_memory="1536m",
        container_cpus=0.5,
    ),
    "pro": TierConfig(
        name="pro",
        template="free",  # 同模板，不同路由策略
        primary_model="zenmux/zenmux/auto",
        routing_models=_PRO_MODELS,
        routing_preference="balanced",
        max_tokens=8192,
        daily_message_limit=None,
        container_memory="1536m",
        container_cpus=0.75,
    ),
    "premium": TierConfig(
        name="premium",
        template="free",  # 同模板，不同路由策略
        primary_model="zenmux/zenmux/auto",
        routing_models=_FREE_MODELS + _PRO_MODELS,  # 全部模型
        routing_preference="performance",
        max_tokens=16384,
        daily_message_limit=None,
        container_memory="2048m",
        container_cpus=1.0,
    ),
}


def get_tier(name: str) -> TierConfig:
    return TIERS.get(name, TIERS["free"])
