"""
PipelineMind FastAPI application entry point.
Port 8000 — all routes prefixed /api/v1/
"""
from __future__ import annotations

import logging
import time

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
from starlette.responses import Response

from api.middleware.logging import StructuredLoggingMiddleware
from api.middleware.pii_guard import PIIGuardMiddleware
from api.routers import chat, pipelines, catalogue, dq, impact
from pm_config import settings

logging.basicConfig(
    level=getattr(logging, settings.log_level, logging.INFO),
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
)

app = FastAPI(
    title="PipelineMind API",
    version="0.1.0",
    description="RAG-Powered Data Engineering Assistant",
    docs_url="/docs",
    redoc_url="/redoc",
)

# ── Middleware ────────────────────────────────────────────────────────────────
app.add_middleware(StructuredLoggingMiddleware)
app.add_middleware(PIIGuardMiddleware)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── Prometheus metrics ────────────────────────────────────────────────────────
REQUEST_COUNT   = Counter("pipelinemind_requests_total", "Total requests", ["method", "endpoint"])
REQUEST_LATENCY = Histogram("pipelinemind_request_latency_seconds", "Request latency", ["endpoint"])

# ── Routers ───────────────────────────────────────────────────────────────────
PREFIX = "/api/v1"
app.include_router(chat.router,       prefix=PREFIX, tags=["chat"])
app.include_router(pipelines.router,  prefix=PREFIX, tags=["pipelines"])
app.include_router(catalogue.router,  prefix=PREFIX, tags=["catalogue"])
app.include_router(dq.router,         prefix=PREFIX, tags=["data-quality"])
app.include_router(impact.router,     prefix=PREFIX, tags=["impact"])

# ── Health & Metrics ──────────────────────────────────────────────────────────
@app.get("/api/v1/health", tags=["observability"])
async def health():
    return {
        "status": "ok",
        "environment": settings.environment,
        "duckdb": str(settings.duckdb_path),
        "chroma": str(settings.chroma_path),
    }


@app.get("/metrics", tags=["observability"])
async def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/api/v1/schema-drift", tags=["observability"])
async def schema_drift():
    from agent.mcp_resources import get_schema_drift_events
    return get_schema_drift_events()


# ── Agent router stats ────────────────────────────────────────────────────────
@app.get("/api/v1/agent/stats", tags=["observability"])
async def agent_stats():
    """LLM router call statistics — shows model usage distribution."""
    from agent.llm_router import router as llm_router
    return llm_router.stats()
