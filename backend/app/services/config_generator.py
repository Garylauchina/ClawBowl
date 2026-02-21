"""Generate per-user openclaw.json from tier-specific templates."""

import json
import secrets
from pathlib import Path

from app.config import settings
from app.models import User
from app.subscriptions.tier import get_tier
from app.subscriptions.zenmux_strategy import get_zenmux_key_for_tier

_TEMPLATE_DIR = Path(__file__).resolve().parent.parent.parent / "docker"

# Template files keyed by tier.template value
_TEMPLATES = {
    "free": _TEMPLATE_DIR / "openclaw-template-free.json",
    "premium": _TEMPLATE_DIR / "openclaw-template-premium.json",
}

# Fallback: legacy single template
_LEGACY_TEMPLATE = _TEMPLATE_DIR / "openclaw-template.json"


def _load_template(template_key: str) -> str:
    """Load template content by key. Falls back to legacy template if needed."""
    path = _TEMPLATES.get(template_key)
    if path and path.exists():
        return path.read_text(encoding="utf-8")
    # Fallback to legacy template
    return _LEGACY_TEMPLATE.read_text(encoding="utf-8")


def generate_gateway_token() -> str:
    """Generate a random per-user gateway auth token."""
    return secrets.token_hex(24)


def render_config(
    user: User,
    gateway_token: str,
    *,
    hooks_token: str | None = None,
) -> dict:
    """Render a full openclaw.json dict for the given user.

    If *hooks_token* is provided it is reused; otherwise a fresh one is
    generated.  Passing the existing token avoids invalidating active webhook
    sessions when the config is re-synced from updated templates.
    """
    tier = get_tier(user.subscription_tier)
    api_key = get_zenmux_key_for_tier(tier, settings.zenmux_api_key)

    raw = _load_template(tier.template)

    if hooks_token is None:
        hooks_token = secrets.token_hex(24)

    raw = raw.replace("{{ ZENMUX_API_KEY }}", api_key)
    raw = raw.replace("{{ MAX_TOKENS }}", str(tier.max_tokens))
    raw = raw.replace("{{ PRIMARY_MODEL }}", tier.primary_model)
    raw = raw.replace("{{ GATEWAY_TOKEN }}", gateway_token)
    raw = raw.replace("{{ HOOKS_TOKEN }}", hooks_token)

    return json.loads(raw)


def write_config(
    user: User,
    gateway_token: str,
    dest_dir: Path,
    *,
    hooks_token: str | None = None,
) -> Path:
    """Write openclaw.json to *dest_dir* and return the file path.

    Passes *hooks_token* through to :func:`render_config` so that
    existing tokens can be preserved across config re-syncs.
    """
    dest_dir.mkdir(parents=True, exist_ok=True)
    config = render_config(user, gateway_token, hooks_token=hooks_token)
    config_path = dest_dir / "openclaw.json"
    config_path.write_text(json.dumps(config, indent=2), encoding="utf-8")
    return config_path


def read_hooks_token(config_dir: Path) -> str | None:
    """Extract the hooks token from an existing openclaw.json, or *None*."""
    config_path = config_dir / "openclaw.json"
    if not config_path.exists():
        return None
    try:
        cfg = json.loads(config_path.read_text(encoding="utf-8"))
        return cfg.get("hooks", {}).get("token")
    except (json.JSONDecodeError, OSError):
        return None
