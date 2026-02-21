"""Application configuration loaded from environment variables."""

from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    # --- Database ---
    database_url: str = "sqlite+aiosqlite:///./clawbowl.db"

    # --- JWT ---
    jwt_secret: str = "change-me-to-a-strong-random-secret"
    jwt_algorithm: str = "HS256"
    jwt_expire_minutes: int = 1440  # 24 hours

    # --- ZenMux ---
    zenmux_api_key: str = ""
    zenmux_base_url: str = "https://zenmux.ai/api/v1"

    # --- Docker / OpenClaw ---
    openclaw_image: str = "clawbowl-openclaw:latest"
    openclaw_port_range_start: int = 19001
    openclaw_port_range_end: int = 19999
    openclaw_data_dir: str = "/var/lib/clawbowl"
    openclaw_container_memory: str = "1536m"
    openclaw_container_cpus: float = 0.5
    openclaw_node_max_old_space: int = 1024
    openclaw_idle_timeout_minutes: int = 30

    # --- Host OpenClaw paths (bind-mounted read-only into containers) ---
    openclaw_host_modules: str = "/usr/lib/node_modules/openclaw"
    openclaw_host_bin: str = "/usr/bin/openclaw"

    # --- APNs Push Notifications ---
    apns_key_path: str = ""
    apns_key_id: str = ""
    apns_team_id: str = ""
    apns_bundle_id: str = "com.gangliu.ClawBowl"
    apns_use_sandbox: bool = True

    # --- External API keys ---
    tavily_api_key: str = ""

    model_config = {
        "env_file": ".env",
        "env_file_encoding": "utf-8",
        "extra": "ignore",
    }


settings = Settings()
