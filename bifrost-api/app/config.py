"""Bifrost API configuration management.

Uses pydantic-settings to load configuration from environment variables
with the BIFROST_ prefix, falling back to .env file values.
"""

from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    """Application settings loaded from environment variables."""

    # NewAPI connection
    newapi_base_url: str = "http://127.0.0.1:3000"
    newapi_admin_token: str = ""

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

    model_config = {"env_prefix": "BIFROST_", "env_file": ".env"}
