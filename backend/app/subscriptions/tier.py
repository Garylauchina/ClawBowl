"""Subscription tier definitions and their resource limits."""

from dataclasses import dataclass


@dataclass(frozen=True)
class TierConfig:
    """Resource limits and model config for a subscription tier."""

    name: str
    primary_model: str
    max_tokens: int
    max_tokens_premium: int
    daily_message_limit: int | None  # None = unlimited
    container_memory: str
    container_cpus: float


TIERS: dict[str, TierConfig] = {
    "free": TierConfig(
        name="free",
        primary_model="zenmux/openai/gpt-4.1-mini",
        max_tokens=1024,
        max_tokens_premium=1024,
        daily_message_limit=100,
        container_memory="1536m",
        container_cpus=0.5,
    ),
    "pro": TierConfig(
        name="pro",
        primary_model="zenmux/openai/gpt-4.1-mini",
        max_tokens=4096,
        max_tokens_premium=4096,
        daily_message_limit=None,
        container_memory="1536m",
        container_cpus=0.75,
    ),
    "premium": TierConfig(
        name="premium",
        primary_model="zenmux/anthropic/claude-sonnet-4.5",
        max_tokens=8192,
        max_tokens_premium=8192,
        daily_message_limit=None,
        container_memory="2048m",
        container_cpus=1.0,
    ),
}


def get_tier(name: str) -> TierConfig:
    return TIERS.get(name, TIERS["free"])
