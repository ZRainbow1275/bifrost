# =============================================================================
# Bifrost API - Multi-stage Docker Build
# =============================================================================
# Builds a lightweight FastAPI application image using a two-stage approach:
#   Stage 1 (builder): Install Python dependencies into a prefix directory
#   Stage 2 (runtime): Copy only the installed packages + application code
#
# Usage:
#   docker build -t bifrost-api .
#   docker run -p 8000:8000 --env-file .env bifrost-api
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Install dependencies
# ---------------------------------------------------------------------------
FROM python:3.12-slim AS builder

WORKDIR /build

COPY requirements.txt .

RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ---------------------------------------------------------------------------
# Stage 2: Runtime image
# ---------------------------------------------------------------------------
FROM python:3.12-slim

# Security: run as non-root user
RUN groupadd -r bifrost && useradd -r -g bifrost -s /sbin/nologin bifrost

WORKDIR /app

# Copy installed Python packages from builder stage
COPY --from=builder /install /usr/local

# Copy application code
COPY app/ ./app/

# Ensure the non-root user owns the workdir
RUN chown -R bifrost:bifrost /app

USER bifrost

EXPOSE 8000

# Health check: verify the /health endpoint responds
HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health')" || exit 1

# Single worker keeps registration state consistent with the local persistent store.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
