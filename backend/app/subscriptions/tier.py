"""Single-user tier configuration.

All resource limits are read from Settings (env); this module just exposes
them as a typed config object consumed by config_generator and instance_manager.
"""

from dataclasses import dataclass

from app.config import settings


@dataclass(frozen=True)
class TierConfig:
    template: str
    primary_model: str
    max_tokens: int
    container_memory: str
    container_cpus: float


DEFAULT_TIER = TierConfig(
    template="free",
    primary_model="zenmux/deepseek/deepseek-chat",
    max_tokens=4096,
    container_memory=settings.openclaw_container_memory,
    container_cpus=settings.openclaw_container_cpus,
)


def get_tier(_name: str = "free") -> TierConfig:
    return DEFAULT_TIER
