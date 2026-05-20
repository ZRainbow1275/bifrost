"""Bifrost API configuration management.

Uses pydantic-settings to load configuration from environment variables
with the BIFROST_ prefix, falling back to .env file values.
"""

from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    """Application settings loaded from environment variables."""

    # NewAPI connection
    newapi_base_url: str = "http://host.docker.internal:3000"
    newapi_admin_token: str = ""

    # Public AI gateway URL returned to users after registration.
    # This must point at the NewAPI gateway domain, not the Bifrost API admin panel.
    public_base_url: str = ""

    # Bifrost API settings
    api_title: str = "Bifrost 管理平台"
    api_version: str = "1.0.0"
    admin_key: str = ""  # Admin API key for protected endpoints

    # Registration settings
    allow_self_register: bool = True
    default_quota: int = 100  # Default quota for new users (in USD)
    max_register_per_day: int = 50

    # Rate limiting
    rate_limit_per_minute: int = 30

    # Registration state persistence
    registration_state_file: str = "/data/registration-state.json"

    # Server B private distribution observability.
    server_b_wg_ip: str = "10.8.0.2"
    readonly_ssh_key: str = "/etc/bifrost-api/ssh/bifrost-readonly.ed25519"
    readonly_user: str = "bifrost-readonly"
    readonly_ssh_timeout_sec: float = 8.0

    # Server B marketplace admin SSH channel (PR-5a, spec section 6.3 + 7.3).
    # IMPORTANT: must be an *independent* SSH user / key pair from the readonly
    # channel above (M11 closure). The forced-command on Server B routes through
    # /usr/local/bin/bifrost-admin-router.sh which whitelists write verbs only.
    admin_user: str = "bifrost-admin"
    admin_ssh_key: str = "/etc/bifrost-api/ssh/bifrost-admin.ed25519"
    admin_ssh_timeout_sec: float = 30.0

    # Optional cross-origin access. Leave empty for same-origin only access.
    cors_allow_origins: str = ""
    cors_allow_credentials: bool = False

    model_config = {"env_prefix": "BIFROST_", "env_file": ".env"}
