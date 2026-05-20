"""Bifrost API - FastAPI application entry point.

Wraps NewAPI's REST API to provide user registration,
model status monitoring, and channel management.
"""

from __future__ import annotations

import logging
from contextlib import asynccontextmanager
from typing import AsyncIterator

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.openapi.docs import (
    get_redoc_html,
    get_swagger_ui_html,
    get_swagger_ui_oauth2_redirect_html,
)
from fastapi.openapi.utils import get_openapi
from fastapi.responses import HTMLResponse, JSONResponse

from .config import Settings
from .dependencies import get_newapi_client
from .routers import channels as channels_router
from .routers import marketplace as marketplace_router
from .routers import mirrors as mirrors_router
from .routers import models as models_router
from .routers import stats as stats_router
from .routers import users as users_router
from .routers.register import page_router as register_page_router
from .routers.register import router as register_router
from .schemas import ApiResponse

logger = logging.getLogger(__name__)

settings = Settings()


def _normalize_path_prefix(path_prefix: str | None) -> str:
    """Normalize an externally visible path prefix such as ``/manage``."""
    if not path_prefix:
        return ""

    normalized = path_prefix.strip()
    if not normalized or normalized == "/":
        return ""
    if not normalized.startswith("/"):
        normalized = f"/{normalized}"
    return normalized.rstrip("/")


def _get_external_path_prefix(request: Request) -> str:
    """Get the proxy path prefix forwarded by the reverse proxy, if any."""
    forwarded_prefix = request.headers.get("x-forwarded-prefix")
    if forwarded_prefix:
        return _normalize_path_prefix(forwarded_prefix)

    root_path = request.scope.get("root_path")
    return _normalize_path_prefix(root_path if isinstance(root_path, str) else None)


def _get_cors_allowed_origins() -> list[str]:
    """Parse a comma-separated allowlist of CORS origins."""
    if not settings.cors_allow_origins.strip():
        return []

    return [
        origin.strip().rstrip("/")
        for origin in settings.cors_allow_origins.split(",")
        if origin.strip()
    ]


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    """Manage application lifecycle.

    Initializes the NewAPI client on startup and ensures graceful
    shutdown of the HTTP connection pool.
    """
    # Startup: eagerly initialize the client to fail fast
    client = await get_newapi_client()
    healthy = await client.health_check()
    if healthy:
        logger.info("NewAPI connection verified at %s", settings.newapi_base_url)
    else:
        logger.warning(
            "NewAPI not reachable at %s -- will retry on first request",
            settings.newapi_base_url,
        )

    yield

    # Shutdown: close the HTTP client
    client = await get_newapi_client()
    await client.close()


app = FastAPI(
    title=settings.api_title,
    version=settings.api_version,
    description="Bifrost 管理平台 - NewAPI 管理接口封装",
    lifespan=lifespan,
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)

cors_allowed_origins = _get_cors_allowed_origins()
if cors_allowed_origins:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=cors_allowed_origins,
        allow_credentials=settings.cors_allow_credentials,
        allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
        allow_headers=["Authorization", "Content-Type", "X-Admin-Key"],
    )

# ------------------------------------------------------------------
# Register routers
# ------------------------------------------------------------------
app.include_router(register_router)
app.include_router(register_page_router)
app.include_router(users_router.router)
app.include_router(models_router.router)
app.include_router(channels_router.router)
app.include_router(stats_router.router)
app.include_router(mirrors_router.router)
app.include_router(marketplace_router.router)


# ------------------------------------------------------------------
# Root endpoints
# ------------------------------------------------------------------


@app.get("/openapi.json", include_in_schema=False)
async def openapi_schema(request: Request) -> JSONResponse:
    """Generate OpenAPI schema with reverse-proxy aware server URLs."""
    external_prefix = _get_external_path_prefix(request)
    servers = []
    if external_prefix:
        servers.append(
            {"url": external_prefix, "description": "Reverse proxy path"}
        )
    servers.append({"url": "/", "description": "Direct container access"})

    schema = get_openapi(
        title=settings.api_title,
        version=settings.api_version,
        description=app.description or "",
        routes=app.routes,
        servers=servers,
    )
    return JSONResponse(schema)


@app.get("/docs", include_in_schema=False)
async def swagger_ui(request: Request) -> HTMLResponse:
    """Serve Swagger UI that works both locally and behind ``/manage``."""
    external_prefix = _get_external_path_prefix(request)
    prefix = external_prefix or ""
    return get_swagger_ui_html(
        openapi_url=f"{prefix}/openapi.json",
        title=f"{settings.api_title} - Swagger UI",
        oauth2_redirect_url=f"{prefix}/docs/oauth2-redirect",
    )


@app.get("/docs/oauth2-redirect", include_in_schema=False)
async def swagger_ui_redirect() -> HTMLResponse:
    """Serve Swagger UI OAuth redirect helper."""
    return get_swagger_ui_oauth2_redirect_html()


@app.get("/redoc", include_in_schema=False)
async def redoc_ui(request: Request) -> HTMLResponse:
    """Serve ReDoc that works both locally and behind ``/manage``."""
    external_prefix = _get_external_path_prefix(request)
    prefix = external_prefix or ""
    return get_redoc_html(
        openapi_url=f"{prefix}/openapi.json",
        title=f"{settings.api_title} - ReDoc",
    )


@app.get("/", response_model=ApiResponse)
async def root() -> ApiResponse:
    """Root endpoint - returns API info."""
    return ApiResponse(
        success=True,
        message="Bifrost 管理平台 API",
        data={
            "version": settings.api_version,
            "docs": "/docs",
        },
    )


@app.get("/health", response_model=ApiResponse)
async def health() -> ApiResponse:
    """Health check - verifies connectivity to NewAPI backend."""
    client = await get_newapi_client()
    healthy = await client.health_check()
    return ApiResponse(
        success=healthy,
        message="服务正常" if healthy else "NewAPI 连接异常",
        data={"newapi_url": settings.newapi_base_url},
    )
