"""Bifrost API - FastAPI application entry point.

Wraps NewAPI's REST API to provide user registration,
model status monitoring, and channel management.
"""

from __future__ import annotations

import logging
from contextlib import asynccontextmanager
from typing import AsyncIterator

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .config import Settings
from .dependencies import get_newapi_client
from .routers import channels as channels_router
from .routers import models as models_router
from .routers import stats as stats_router
from .routers import users as users_router
from .routers.register import page_router as register_page_router
from .routers.register import router as register_router
from .schemas import ApiResponse

logger = logging.getLogger(__name__)

settings = Settings()


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
)

# CORS middleware - permissive defaults for development
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
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


# ------------------------------------------------------------------
# Root endpoints
# ------------------------------------------------------------------


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
