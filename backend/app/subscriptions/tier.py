"""Subscription tier definitions and their resource limits.

Tier 设计:
  - free:    免费用户，使用中国大陆免费/极低价 LLM（小米 MiMo、DeepSeek、智谱 GLM）
  - pro:     付费订阅用户，使用 ZenMux 智能路由 + 高级中国 LLM
  - premium: 高级订阅用户，更高配额 + 全部高级模型
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class TierConfig:
    """Resource limits and model config for a subscription tier."""

    name: str
    template: str  # "free" or "premium" — 选择哪个配置模板
    primary_model: str  # OpenClaw primary model reference: {provider}/{model_id}
    max_tokens: int
    daily_message_limit: int | None  # None = unlimited
    container_memory: str
    container_cpus: float


TIERS: dict[str, TierConfig] = {
    "free": TierConfig(
        name="free",
        template="free",
        primary_model="zenmux/xiaomi/mimo-v2-flash",
        max_tokens=4096,
        daily_message_limit=50,
        container_memory="1536m",
        container_cpus=0.5,
    ),
    "pro": TierConfig(
        name="pro",
        template="premium",
        primary_model="zenmux/zenmux/auto",
        max_tokens=8192,
        daily_message_limit=None,
        container_memory="1536m",
        container_cpus=0.75,
    ),
    "premium": TierConfig(
        name="premium",
        template="premium",
        primary_model="zenmux/zenmux/auto",
        max_tokens=16384,
        daily_message_limit=None,
        container_memory="2048m",
        container_cpus=1.0,
    ),
}


def get_tier(name: str) -> TierConfig:
    return TIERS.get(name, TIERS["free"])
