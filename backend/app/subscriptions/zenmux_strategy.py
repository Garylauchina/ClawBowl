"""ZenMux call strategy based on user subscription tier.

This module is a placeholder for future per-tier routing / rate-limiting logic.
Currently all tiers share the same ZenMux API key; the per-user OpenClaw
instance config already selects the appropriate model and maxTokens.
"""

from app.subscriptions.tier import TierConfig


def get_zenmux_key_for_tier(tier: TierConfig, default_key: str) -> str:
    """Return the ZenMux API key to use for the given tier.

    Future: premium tiers could use a dedicated high-priority key.
    """
    # For now, all tiers share the same key.
    return default_key
