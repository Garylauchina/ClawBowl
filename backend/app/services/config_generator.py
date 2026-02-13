"""Generate per-user openclaw.json from the template."""

import json
import secrets
from pathlib import Path

from app.config import settings
from app.models import User
from app.subscriptions.tier import get_tier
from app.subscriptions.zenmux_strategy import get_zenmux_key_for_tier

_TEMPLATE_PATH = Path(__file__).resolve().parent.parent.parent / "docker" / "openclaw-template.json"


def _load_template() -> str:
    return _TEMPLATE_PATH.read_text(encoding="utf-8")


def generate_gateway_token() -> str:
    """Generate a random per-user gateway auth token."""
    return secrets.token_hex(24)


def render_config(user: User, gateway_token: str) -> dict:
    """Render a full openclaw.json dict for the given user."""
    tier = get_tier(user.subscription_tier)
    api_key = get_zenmux_key_for_tier(tier, settings.zenmux_api_key)

    raw = _load_template()

    # Replace template placeholders
    raw = raw.replace("{{ ZENMUX_API_KEY }}", api_key)
    raw = raw.replace("{{ MAX_TOKENS }}", str(tier.max_tokens))
    raw = raw.replace("{{ MAX_TOKENS_PREMIUM }}", str(tier.max_tokens_premium))
    raw = raw.replace("{{ PRIMARY_MODEL }}", tier.primary_model)
    raw = raw.replace("{{ GATEWAY_TOKEN }}", gateway_token)

    return json.loads(raw)


def write_config(user: User, gateway_token: str, dest_dir: Path) -> Path:
    """Write openclaw.json to *dest_dir* and return the file path."""
    dest_dir.mkdir(parents=True, exist_ok=True)
    config = render_config(user, gateway_token)
    config_path = dest_dir / "openclaw.json"
    config_path.write_text(json.dumps(config, indent=2), encoding="utf-8")
    return config_path
