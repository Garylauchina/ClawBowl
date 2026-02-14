"""Subscription tier definitions and their resource limits.

Tier 设计:
  - free:    国内免费/极低价 LLM（DeepSeek、小米 MiMo、智谱 GLM）
  - pro:     国内高级 LLM（待 1.0 发布后配置）
  - premium: 全部高级 LLM（待 1.0 发布后配置）
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class TierConfig:
    """Resource limits and model config for a subscription tier."""

    name: str
    template: str  # 配置模板: "free" or "premium"
    primary_model: str  # OpenClaw primary model: zenmux/{model_id}
    max_tokens: int
    daily_message_limit: int | None  # None = unlimited
    container_memory: str
    container_cpus: float


TIERS: dict[str, TierConfig] = {
    "free": TierConfig(
        name="free",
        template="free",
        primary_model="zenmux/deepseek/deepseek-chat",
        max_tokens=4096,
        daily_message_limit=50,
        container_memory="1536m",
        container_cpus=0.5,
    ),
    "pro": TierConfig(
        name="pro",
        template="free",  # TODO: 1.0 后切换到 premium 模板
        primary_model="zenmux/deepseek/deepseek-chat",
        max_tokens=8192,
        daily_message_limit=None,
        container_memory="1536m",
        container_cpus=0.75,
    ),
    "premium": TierConfig(
        name="premium",
        template="free",  # TODO: 1.0 后切换到 premium 模板
        primary_model="zenmux/deepseek/deepseek-chat",
        max_tokens=16384,
        daily_message_limit=None,
        container_memory="2048m",
        container_cpus=1.0,
    ),
}


def get_tier(name: str) -> TierConfig:
    return TIERS.get(name, TIERS["free"])
