"""Generate per-user openclaw.json from templates."""

import json
import secrets
from pathlib import Path

from app.config import settings
from app.models import User
from app.subscriptions.tier import get_tier

_TEMPLATE_DIR = Path(__file__).resolve().parent.parent.parent / "docker"

_TEMPLATES = {
    "free": _TEMPLATE_DIR / "openclaw-template-free.json",
    "premium": _TEMPLATE_DIR / "openclaw-template-premium.json",
}


def _load_template(template_key: str) -> str:
    path = _TEMPLATES.get(template_key, _TEMPLATES["free"])
    return path.read_text(encoding="utf-8")


def generate_gateway_token() -> str:
    return secrets.token_hex(24)


def render_config(
    user: User,
    gateway_token: str,
    *,
    hooks_token: str | None = None,
) -> dict:
    tier = get_tier(user.subscription_tier)
    api_key = settings.zenmux_api_key

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
    dest_dir.mkdir(parents=True, exist_ok=True)
    config = render_config(user, gateway_token, hooks_token=hooks_token)
    config_path = dest_dir / "openclaw.json"
    config_path.write_text(json.dumps(config, indent=2), encoding="utf-8")
    return config_path


def read_hooks_token(config_dir: Path) -> str | None:
    config_path = config_dir / "openclaw.json"
    if not config_path.exists():
        return None
    try:
        cfg = json.loads(config_path.read_text(encoding="utf-8"))
        return cfg.get("hooks", {}).get("token")
    except (json.JSONDecodeError, OSError):
        return None
