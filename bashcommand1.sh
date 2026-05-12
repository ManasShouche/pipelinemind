before doing the project do you have any queries to ask from my side just to be clear before starting the project ?
and yes let me know what all things we will be building like robust production ready pipeline , MCPs, all the things we gonna build
for llm call we will be using groq api which is "YOUR_GROQ_API_KEY_HERE" ask every single detail you want from me and tell me what we gonna do
12:33 PM
Claude responded: Good.

Identified clarification needs before architecting Groq-powered PipelineMind system
Identified clarification needs before architecting Groq-powered PipelineMind system
The user wants to build PipelineMind as described in the SRS document, but using Groq API instead of Anthropic Claude. Before starting, I need to ask clarifying questions to understand the full scope and any constraints.
Let me think about what I need to know before writing the bash script.
Done
Good. Before writing a single line of code, here is exactly what we are building and every open question I need answered.
What We Are Building
A production-grade, three-tier agentic AI assistant called PipelineMind with the following layers:
Layer 1 — Ingestion Pipeline
AST-based Python chunker (tree-sitter), SQL statement chunker, YAML block chunker, Markdown semantic chunker
dbt manifest/catalog parser
LLM-generated summaries per chunk (embed-summary/retrieve-full pattern)
Dual embedders: all-mpnet-base-v2 (docs) + codebert-base (code)
ChromaDB persistent vector store + BM25 sparse index
File watcher for incremental re-indexing (watchdog)
PII registry enrichment + git commit hash tagging
Layer 2 — RAG + Agent Engine (FastAPI, Port 8000)
HyDE query processing
Hybrid retrieval: ChromaDB dense + BM25 sparse, fused via Reciprocal Rank Fusion
Cross-encoder re-ranking (ms-marco-MiniLM-L-6-v2)
Intent classifier (5 intents: CODE_QA, CATALOGUE, HEALTH, ACTION, GENERAL)
Claude/Groq tool-use agent loop (max 5 iterations)
MCP server with 6 tools + 1 schema drift Resource + 1 Prompt primitive
Pydantic validation + self-correction loop
PII guard middleware, circuit breakers, exponential backoff
SSE streaming on all 14 REST endpoints
structlog JSON logging + Prometheus metrics
Layer 3 — Streamlit UI (Port 8501)
Streaming chat panel with citations and confidence scores
Pipeline health dashboard with sparklines
Data catalogue browser with interactive lineage DAG (streamlit-agraph)
Human-in-the-loop approval gate component
Schema drift sidebar banner
/diagnose_pipeline slash command
Data Layer
DuckDB metadata store (6 tables: tables, columns, lineage_edges, pipeline_runs, slo_definitions, schema_snapshots)
Synthetic fixtures: 5 Python pipelines, 3 SQL files, 3 YAML configs, dbt project, 30-day run logs
MCP Tools (6) trigger_dq_check, get_pipeline_status, get_lineage_graph, analyze_lineage_impact (What-If Engine), search_pii_tables, get_slo_report
Eval RAG evaluation notebook: MRR@5, NDCG@5, Recall@10, ablation study, latency curves
Containerization Full Docker Compose single-command startup, uv for dependency management
Questions I Need Answered Before Starting
Groq model selection — The SRS uses Claude for three distinct tasks: HyDE generation, chunk summary generation (cheap/fast), and agent reasoning + tool-use. Groq does not support MCP tool-use natively the same way Anthropic does. Which Groq models should I use for each role? Suggested defaults:
Summary generation (cheap/fast): llama3-8b-8192
HyDE + intent classification: llama3-70b-8192
Agent reasoning + tool-use: llama-3.3-70b-versatile (supports function calling)
Confirm or override these.
MCP transport — The SRS specifies stdio transport for local demo. Since we are replacing Anthropic's MCP SDK with Groq + function calling, do you want a true MCP server (stdio via the mcp Python SDK) wired to Groq function-calling, or a FastAPI-native tool-dispatch layer that behaves identically but without the MCP SDK dependency? The true MCP SDK approach is cleaner architecturally but adds complexity.
Synthetic data scope — Should I generate fully realistic synthetic pipeline code (actual Python ETL scripts with pandas/SQLAlchemy logic, real SQL DDL/DML, real YAML Airflow DAG configs) or minimal stubs sufficient to demonstrate the RAG chunking and retrieval?
Great Expectations — The trigger_dq_check tool is supposed to run actual Great Expectations suites. Do you want a real GE integration against DuckDB, or a simulated DQ check that returns realistic mock results?
ChromaDB persistence path — Where should ChromaDB persist its data on your Mac? Default would be /Users/as-mac-1282/Developer/genai_mini/pipelinemind/data/chroma_db. Confirm or override.
Port conflicts — Are ports 8000 (FastAPI) and 8501 (Streamlit) free on your machine?
Python version — The script will use uv to create a virtual environment. What Python version is available (python3 --version)? I will target 3.11 as the minimum.
Docker — Do you want the Docker Compose setup built and functional from day one, or focus on bare-metal local dev first and add Docker later?
Phase scope for first script — The full system is 8 phases. Should the first bash script deliver the complete end-to-end system in one shot, or do you want it phased (e.g., Phase 1+2 first, then Agent+MCP, then UI)?
Groq API key handling — You have shared the key in plain text. I will write it into a .env file that is gitignored. Confirm this is acceptable, or should I use a secrets manager pattern?
You said: confirm
confirm
use which would be best for production ready code
fully realistic synthetic pipeline code
a real GE integration against DuckDB
Confirm and use a venv to install any packages
use different ports the streamlit port is available
Python 3.11.1
Docker Compose setup built and functional from day one
phased
write it into a .env file that is gitignored.
12:44 PM

Architected comprehensive production-grade bash script for phased pipeline deployment
Architected comprehensive production-grade bash script for phased pipeline deployment
The user has confirmed all the details. Let me now plan Phase 1+2 of the implementation.
For question 2 about MCP transport - "use which would be best for production ready code" - I'll use the true MCP SDK with stdio transport as it's the proper architectural approach, but since we're using Groq instead of Anthropic, I'll implement MCP tools as FastAPI-native function-calling tools that mirror the MCP interface. Actually, for production-ready code, I'll use the mcp Python SDK with stdio transport wired to Groq's function calling API. This is the cleanest approach.
For port 8000 - FastAPI will stay at 8000. For Streamlit, I'll use 8502 since the user said 8501 is available but let me re-read... "use different ports the streamlit port is available" - I think they mean use different ports than what's specified, or that the streamlit port IS available. Let me re-read: "the streamlit port is available" - so 8501 is available. But they said "use different ports" - maybe they mean use different ports for FastAPI? Or maybe they want me to pick ports that won't conflict. I'll use 8000 for FastAPI and 8501 for Streamlit as originally planned, since the user confirmed 8501 is available.
Wait, re-reading: "use different ports the streamlit port is available" - I think this means: use different ports (don't use the default ones), but the streamlit port (8501) IS available. So maybe FastAPI should use a different port? Or they just mean 8501 is fine for Streamlit. I'll use 8000 for FastAPI and 8501 for Streamlit.
Now, for Phase 1+2, I'll deliver:
Complete project structure
Docker Compose
Synthetic data (realistic Python ETL, SQL, YAML pipelines)
DuckDB schema and seed data
All 4 chunkers (AST Python, SQL, YAML, Markdown)
dbt manifest parser
Summary generator (Groq llama3-8b)
Dual embedders
ChromaDB + BM25 writers
File watcher
PII registry
HyDE query processor
Hybrid retrieval (dense + BM25 + RRF)
Cross-encoder re-ranker
Context builder …
Show less

Check Python version and available tools on the system

Script
The environment is my container, not the user's Mac. The user's Mac has Python 3.11.1 as confirmed earlier. I'm running in a container environment.
The script I write will be for the user's Mac (MacOS with Python 3.11.1). I'll write the bash script targeting MacOS Python 3.11.
Since I can't run the script in my container (wrong environment), I just need to write the comprehensive bash script that the user will run on their Mac.
Let me now write the complete bash script. I'll create it as a file and present it to the user.
Key notes:
Target: MacOS with Python 3.11.1
uv for package management
Docker Compose for containerization
Groq API key in .env file
All files created via heredocs
Let me write the complete script now.
Show less

Prepare workspace for script generation
bash
mkdir -p /tmp/pipelinemind_script && echo "workspace ready"
Output
workspace ready
Good. Now I'll write the complete bash script. Since I can't run it here (wrong OS, no Python 3.11, no docker), I'll just create the file and present it.
Let me write the complete comprehensive bash script for Phase 1+2 of PipelineMind.
This will be very long. Let me write it now.

PipelineMind Phase 1+2 complete setup script - Foundation + RAG Core
bash
#!/usr/bin/env bash
# ==============================================================================
# PipelineMind — Phase 1 + 2: Foundation & RAG Core
# MacOS | Python 3.11 | Groq | ChromaDB | DuckDB | Docker Compose
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${GREEN}[PM]${NC} $*"; }
step() { echo -e "\n${BLUE}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[FATAL]${NC} $*" >&2; exit 1; }

BASE_DIR="/Users/as-mac-1282/Developer/genai_mini"
PROJECT_DIR="$BASE_DIR/pipelinemind"
GROQ_API_KEY="YOUR_GROQ_API_KEY_HERE"
PYTHON_BIN=""

# ── Preflight ─────────────────────────────────────────────────────────────────
step "Preflight checks"

for candidate in python3.11 python3; do
  if command -v "$candidate" &>/dev/null; then
    ver=$("$candidate" --version 2>&1 | awk '{print $2}')
    major=$(echo "$ver" | cut -d. -f1)
    minor=$(echo "$ver" | cut -d. -f2)
    if [[ "$major" -ge 3 && "$minor" -ge 11 ]]; then
      PYTHON_BIN=$(command -v "$candidate")
      log "Python: $PYTHON_BIN ($ver)"
      break
    fi
  fi
done
[[ -z "$PYTHON_BIN" ]] && die "Python >= 3.11 not found. Install via: brew install python@3.11"

command -v docker &>/dev/null || die "Docker not found. Install Docker Desktop: https://docs.docker.com/desktop/mac/"
command -v git    &>/dev/null || die "git not found."
log "Docker: $(docker --version | head -1)"
log "git:    $(git --version)"

# ── Directory tree ─────────────────────────────────────────────────────────────
step "Creating directory tree"

mkdir -p "$PROJECT_DIR"/{ingestion/chunkers,retrieval,agent/tools,api/routers,api/models,api/middleware,ui/pages,ui/components,data/pipeline_repo,data/sql,data/dags,data/dbt_project/models,data/catalogue,data/run_logs,data/schema_snapshots,data/chroma_db,data/model_cache,db,notebooks,tests/unit,tests/integration,tests/eval,logs,slides}

cd "$PROJECT_DIR"
log "Project root: $PROJECT_DIR"

# ── .gitignore ────────────────────────────────────────────────────────────────
step "Writing configuration files"

cat << 'GITEOF' > .gitignore
.env
.venv/
__pycache__/
*.pyc
*.pyo
*.egg-info/
dist/
build/
.pytest_cache/
.coverage
htmlcov/
data/chroma_db/
data/pipelinemind.db
data/bm25_index.pkl
data/model_cache/
logs/
*.log
slides/
.DS_Store
GITEOF

# ── .env ──────────────────────────────────────────────────────────────────────
cat > .env << ENVEOF
# ---------------------------------------------------------------
# PipelineMind Environment — DO NOT COMMIT
# Rotate GROQ_API_KEY after first successful run
# ---------------------------------------------------------------
GROQ_API_KEY=${GROQ_API_KEY}
GROQ_MODEL_FAST=llama3-8b-8192
GROQ_MODEL_STRONG=llama3-70b-8192
GROQ_MODEL_AGENT=llama-3.3-70b-versatile

CHROMA_PATH=./data/chroma_db
DUCKDB_PATH=./data/pipelinemind.db
PIPELINE_REPO_PATH=./data/pipeline_repo
BM25_INDEX_PATH=./data/bm25_index.pkl
EMBED_CACHE_DIR=./data/model_cache

FASTAPI_HOST=0.0.0.0
FASTAPI_PORT=8000
STREAMLIT_PORT=8501

LOG_LEVEL=INFO
ENVIRONMENT=development

MAX_CONTEXT_TOKENS=6000
TOP_K_DENSE=20
TOP_K_SPARSE=20
TOP_K_FUSED=10
TOP_K_RERANK=5
RRF_K=60
CONFIDENCE_THRESHOLD=0.6
HYDE_ENABLED=true
RERANK_ENABLED=true
AGENT_MAX_ITERATIONS=5
ENVEOF

cp .env .env.example && sed -i '' "s|${GROQ_API_KEY}|your_groq_api_key_here|g" .env.example

# ── pyproject.toml ────────────────────────────────────────────────────────────
cat << 'PYEOF' > pyproject.toml
[project]
name = "pipelinemind"
version = "0.1.0"
description = "RAG-Powered Data Engineering Assistant via MCP"
requires-python = ">=3.11"
dependencies = [
    "groq>=0.9.0",
    "chromadb>=0.5.0",
    "rank-bm25>=0.2.2",
    "sentence-transformers>=3.0.0",
    "tree-sitter>=0.22.0",
    "tree-sitter-python>=0.22.0",
    "fastapi>=0.111.0",
    "uvicorn[standard]>=0.30.0",
    "streamlit>=1.35.0",
    "duckdb>=1.0.0",
    "pydantic>=2.0.0",
    "pydantic-settings>=2.0.0",
    "structlog>=24.0.0",
    "prometheus-client>=0.20.0",
    "watchdog>=4.0.0",
    "sqlalchemy>=2.0.0",
    "pandas>=2.0.0",
    "numpy>=1.26.0",
    "scikit-learn>=1.4.0",
    "tenacity>=8.0.0",
    "httpx>=0.27.0",
    "sse-starlette>=2.0.0",
    "python-dotenv>=1.0.0",
    "pyyaml>=6.0.0",
    "pytest>=8.0.0",
    "pytest-asyncio>=0.23.0",
    "great-expectations>=0.18.0",
    "mcp>=1.0.0",
    "streamlit-agraph>=0.0.45",
]

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = [
    "config.py", "ingestion", "retrieval", "agent", "api", "ui", "db"
]

[tool.pytest.ini_options]
asyncio_mode = "auto"
testpaths = ["tests"]
log_cli = true
log_level = "INFO"

[tool.ruff]
line-length = 100
target-version = "py311"
PYEOF

# ── Dockerfiles ───────────────────────────────────────────────────────────────
step "Writing Docker files"

cat << 'DFAPI' > Dockerfile.api
FROM python:3.11-slim AS base
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential curl git \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --upgrade pip uv

COPY pyproject.toml .
RUN uv pip install --system -e ".[dev]" 2>/dev/null || uv pip install --system \
        groq chromadb rank-bm25 sentence-transformers tree-sitter tree-sitter-python \
        fastapi "uvicorn[standard]" duckdb "pydantic>=2" pydantic-settings \
        structlog prometheus-client watchdog sqlalchemy pandas numpy scikit-learn \
        tenacity httpx sse-starlette python-dotenv pyyaml great-expectations mcp

COPY . .
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
    CMD curl -f http://localhost:8000/api/v1/health || exit 1

CMD ["uvicorn", "api.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", "--loop", "uvloop"]
DFAPI

cat << 'DFUI' > Dockerfile.ui
FROM python:3.11-slim AS base
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential curl \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --upgrade pip uv

COPY pyproject.toml .
RUN uv pip install --system \
        groq chromadb rank-bm25 sentence-transformers \
        streamlit duckdb "pydantic>=2" pydantic-settings \
        structlog httpx python-dotenv pyyaml streamlit-agraph

COPY . .
EXPOSE 8501

CMD ["streamlit", "run", "ui/app.py", \
     "--server.port=8501", "--server.address=0.0.0.0", \
     "--server.headless=true", "--browser.gatherUsageStats=false"]
DFUI

cat << 'DCEOF' > docker-compose.yml
version: "3.9"

x-common-env: &common-env
  env_file: .env
  restart: unless-stopped

services:
  api:
    <<: *common-env
    build:
      context: .
      dockerfile: Dockerfile.api
    container_name: pipelinemind_api
    ports:
      - "8000:8000"
    volumes:
      - ./data:/app/data
      - ./logs:/app/logs
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/api/v1/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s

  ui:
    <<: *common-env
    build:
      context: .
      dockerfile: Dockerfile.ui
    container_name: pipelinemind_ui
    ports:
      - "8501:8501"
    volumes:
      - ./data:/app/data
    depends_on:
      api:
        condition: service_healthy

volumes:
  pipelinemind_data:
DCEOF

# ── config.py ────────────────────────────────────────────────────────────────
step "Writing core config module"

cat << 'CFGEOF' > config.py
"""
Shared Pydantic-Settings configuration for PipelineMind.
All modules import `settings` from here — never read os.environ directly.
"""
from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
        case_sensitive=False,
    )

    # Groq
    groq_api_key: str = Field(..., description="Groq Cloud API key")
    groq_model_fast: str = "llama3-8b-8192"
    groq_model_strong: str = "llama3-70b-8192"
    groq_model_agent: str = "llama-3.3-70b-versatile"

    # Storage paths
    chroma_path: Path = Path("./data/chroma_db")
    duckdb_path: Path = Path("./data/pipelinemind.db")
    pipeline_repo_path: Path = Path("./data/pipeline_repo")
    bm25_index_path: Path = Path("./data/bm25_index.pkl")
    embed_cache_dir: Path = Path("./data/model_cache")

    # Server
    fastapi_host: str = "0.0.0.0"
    fastapi_port: int = 8000
    streamlit_port: int = 8501

    # Logging
    log_level: str = "INFO"
    environment: str = "development"

    # RAG knobs
    max_context_tokens: int = 6000
    top_k_dense: int = 20
    top_k_sparse: int = 20
    top_k_fused: int = 10
    top_k_rerank: int = 5
    rrf_k: int = 60
    confidence_threshold: float = 0.6
    hyde_enabled: bool = True
    rerank_enabled: bool = True

    # Agent
    agent_max_iterations: int = 5


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()


settings: Settings = get_settings()
CFGEOF

# ── __init__ stubs ────────────────────────────────────────────────────────────
for pkg in ingestion ingestion/chunkers retrieval agent agent/tools api api/routers api/models api/middleware ui ui/pages ui/components db tests/unit tests/integration tests/eval; do
  touch "$PROJECT_DIR/$pkg/__init__.py"
done

# ==============================================================================
# SECTION: Synthetic Pipeline Data
# ==============================================================================
step "Writing synthetic pipeline data"

# ── orders_pipeline.py ────────────────────────────────────────────────────────
cat << 'PYEOF' > data/pipeline_repo/orders_pipeline.py
"""
Orders incremental ETL pipeline.
Reads modified orders from the OLTP source, applies business transformations,
and merges into the warehouse orders_fact table using an upsert strategy.
Pipeline SLO: >= 99.5 % success rate, <= 5 min latency per run.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Optional

import pandas as pd
from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine

logger = logging.getLogger(__name__)

STATUS_MAP: dict[str, int] = {
    "pending": 0,
    "confirmed": 1,
    "shipped": 2,
    "delivered": 3,
    "cancelled": -1,
}

HIGH_VALUE_THRESHOLD_USD = 1_000.0


@dataclass
class PipelineResult:
    status: str
    rows_extracted: int
    rows_loaded: int
    duration_secs: float
    error: Optional[str] = None


class OrdersPipeline:
    """
    Incremental Orders ETL pipeline.

    Uses a MERGE (upsert) strategy rather than INSERT OVERWRITE to handle
    late-arriving order status updates without duplicate rows.  The watermark
    is stored in the pipeline_state table and advanced only on success.

    Args:
        source_conn: SQLAlchemy connection string for the OLTP source.
        target_conn: SQLAlchemy connection string for the warehouse.
        lookback_hours: Default look-back window when no watermark exists.
    """

    STAGING_TABLE = "stg_orders_tmp"
    FACT_TABLE = "orders_fact"

    def __init__(
        self,
        source_conn: str,
        target_conn: str,
        lookback_hours: int = 24,
    ) -> None:
        self.source_engine: Engine = create_engine(source_conn, pool_pre_ping=True)
        self.target_engine: Engine = create_engine(target_conn, pool_pre_ping=True)
        self.lookback_hours = lookback_hours

    # ------------------------------------------------------------------
    # Extract
    # ------------------------------------------------------------------

    def extract(self, watermark: datetime) -> pd.DataFrame:
        """Pull orders modified since *watermark* from the source OLTP."""
        query = text(
            """
            SELECT
                order_id,
                customer_id,
                product_id,
                order_status,
                total_amount,
                currency,
                shipping_address_id,
                created_at,
                updated_at
            FROM orders
            WHERE updated_at >= :watermark
            ORDER BY updated_at ASC
            """
        )
        with self.source_engine.connect() as conn:
            df = pd.read_sql(query, conn, params={"watermark": watermark})
        logger.info("Extracted %d orders since %s", len(df), watermark.isoformat())
        return df

    # ------------------------------------------------------------------
    # Transform
    # ------------------------------------------------------------------

    def transform(self, df: pd.DataFrame) -> pd.DataFrame:
        """Apply business rules, type coercions, and derived column logic."""
        if df.empty:
            return df

        df = df.copy()
        df["order_date"] = pd.to_datetime(df["created_at"]).dt.date
        df["order_month"] = pd.to_datetime(df["created_at"]).dt.to_period("M").astype(str)
        df["is_high_value"] = df["total_amount"] > HIGH_VALUE_THRESHOLD_USD
        df["status_code"] = df["order_status"].map(STATUS_MAP).fillna(-99).astype(int)
        df["total_amount"] = df["total_amount"].round(2)
        df["etl_loaded_at"] = datetime.utcnow()

        # Drop rows with missing mandatory keys
        before = len(df)
        df = df.dropna(subset=["order_id", "customer_id"])
        dropped = before - len(df)
        if dropped:
            logger.warning("Dropped %d rows with null primary keys", dropped)

        return df

    # ------------------------------------------------------------------
    # Load
    # ------------------------------------------------------------------

    def load(self, df: pd.DataFrame) -> int:
        """MERGE transformed records into the warehouse fact table."""
        if df.empty:
            return 0

        # Stage into a temporary table
        df.to_sql(
            self.STAGING_TABLE,
            self.target_engine,
            if_exists="replace",
            index=False,
            method="multi",
            chunksize=500,
        )

        merge_sql = text(
            f"""
            INSERT INTO {self.FACT_TABLE}
                SELECT * FROM {self.STAGING_TABLE}
            ON CONFLICT (order_id) DO UPDATE SET
                order_status     = EXCLUDED.order_status,
                status_code      = EXCLUDED.status_code,
                total_amount     = EXCLUDED.total_amount,
                is_high_value    = EXCLUDED.is_high_value,
                updated_at       = EXCLUDED.updated_at,
                etl_loaded_at    = EXCLUDED.etl_loaded_at
            """
        )
        with self.target_engine.begin() as conn:
            conn.execute(merge_sql)

        logger.info("Merged %d records into %s", len(df), self.FACT_TABLE)
        return len(df)

    # ------------------------------------------------------------------
    # Watermark management
    # ------------------------------------------------------------------

    def _get_watermark(self) -> datetime:
        with self.target_engine.connect() as conn:
            row = conn.execute(
                text("SELECT last_watermark FROM pipeline_state WHERE pipeline_id = 'orders'")
            ).fetchone()
        if row:
            return row[0]
        return datetime.utcnow() - timedelta(hours=self.lookback_hours)

    def _advance_watermark(self, new_watermark: datetime) -> None:
        with self.target_engine.begin() as conn:
            conn.execute(
                text(
                    """
                    INSERT INTO pipeline_state (pipeline_id, last_watermark)
                    VALUES ('orders', :ts)
                    ON CONFLICT (pipeline_id) DO UPDATE SET last_watermark = EXCLUDED.last_watermark
                    """
                ),
                {"ts": new_watermark},
            )

    # ------------------------------------------------------------------
    # Entrypoint
    # ------------------------------------------------------------------

    def run(self, watermark: Optional[datetime] = None) -> PipelineResult:
        """Execute the full extract → transform → load cycle."""
        start = datetime.utcnow()
        watermark = watermark or self._get_watermark()

        try:
            raw_df = self.extract(watermark)
            transformed_df = self.transform(raw_df)
            rows_loaded = self.load(transformed_df)
            self._advance_watermark(datetime.utcnow())

            duration = (datetime.utcnow() - start).total_seconds()
            logger.info("orders pipeline SUCCESS — %d rows in %.2fs", rows_loaded, duration)
            return PipelineResult(
                status="success",
                rows_extracted=len(raw_df),
                rows_loaded=rows_loaded,
                duration_secs=duration,
            )
        except Exception as exc:
            duration = (datetime.utcnow() - start).total_seconds()
            logger.error("orders pipeline FAILED after %.2fs: %s", duration, exc, exc_info=True)
            return PipelineResult(
                status="failed",
                rows_extracted=0,
                rows_loaded=0,
                duration_secs=duration,
                error=str(exc),
            )
PYEOF

# ── users_pipeline.py ─────────────────────────────────────────────────────────
cat << 'PYEOF' > data/pipeline_repo/users_pipeline.py
"""
Users SCD Type-2 dimension pipeline.
Tracks historical changes to user attributes using Slowly Changing Dimension
Type-2 (SCD2) logic: closes old records with an end date and inserts new ones.

PII notice: this pipeline processes user_id, email, and phone_number.
All PII columns are tagged in the DuckDB catalogue under pii_class = 'PII_HIGH'.
"""
from __future__ import annotations

import hashlib
import logging
from datetime import date, datetime
from typing import Optional

import pandas as pd
from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine

logger = logging.getLogger(__name__)

PII_COLUMNS = ["email", "phone_number", "full_name", "date_of_birth"]
SURROGATE_COLUMNS = ["email", "phone_number", "address_id", "subscription_tier"]


def _row_hash(row: pd.Series) -> str:
    """MD5 fingerprint of SCD-tracked columns to detect row-level changes."""
    payload = "|".join(str(row.get(c, "")) for c in sorted(SURROGATE_COLUMNS))
    return hashlib.md5(payload.encode()).hexdigest()


class UsersDimensionPipeline:
    """
    Implements SCD Type-2 for the users dimension table.

    On each run:
      1. Pull current snapshot of source users.
      2. Hash SCD-tracked columns to detect attribute changes.
      3. CLOSE expired records by setting is_current=false, valid_to=today.
      4. INSERT new records for changed or new users with is_current=true.

    The natural key is user_id; the surrogate key is user_sk (auto-increment).
    """

    SOURCE_TABLE = "users"
    DIM_TABLE = "dim_users"

    def __init__(self, source_conn: str, target_conn: str) -> None:
        self.source_engine: Engine = create_engine(source_conn, pool_pre_ping=True)
        self.target_engine: Engine = create_engine(target_conn, pool_pre_ping=True)

    # ------------------------------------------------------------------
    # Extract
    # ------------------------------------------------------------------

    def extract_source(self) -> pd.DataFrame:
        """Full snapshot of source users (SCD2 requires full comparison)."""
        query = text(
            """
            SELECT
                user_id,
                full_name,
                email,
                phone_number,
                date_of_birth,
                address_id,
                subscription_tier,
                created_at
            FROM users
            WHERE is_deleted = false
            """
        )
        with self.source_engine.connect() as conn:
            df = pd.read_sql(query, conn)
        df["row_hash"] = df.apply(_row_hash, axis=1)
        logger.info("Extracted %d source users", len(df))
        return df

    def extract_current_dim(self) -> pd.DataFrame:
        """Fetch currently active dimension records."""
        query = text(
            f"SELECT user_id, row_hash FROM {self.DIM_TABLE} WHERE is_current = true"
        )
        with self.target_engine.connect() as conn:
            return pd.read_sql(query, conn)

    # ------------------------------------------------------------------
    # Transform — SCD2 delta detection
    # ------------------------------------------------------------------

    def compute_deltas(
        self, source_df: pd.DataFrame, current_df: pd.DataFrame
    ) -> tuple[pd.DataFrame, pd.DataFrame]:
        """
        Returns (new_records, expired_user_ids).

        A record is NEW if:
          - user_id does not exist in the dimension (brand new user), OR
          - user_id exists but row_hash differs (attribute change).
        A record is EXPIRED if its user_id is in the dimension with a different hash.
        """
        merged = source_df.merge(
            current_df, on="user_id", how="left", suffixes=("_src", "_dim")
        )
        # Brand new users
        new_users = merged[merged["row_hash_dim"].isna()].copy()
        # Changed users
        changed_users = merged[
            merged["row_hash_dim"].notna()
            & (merged["row_hash_src"] != merged["row_hash_dim"])
        ].copy()

        new_records = pd.concat([new_users, changed_users], ignore_index=True)
        new_records = new_records.drop(columns=["row_hash_dim"], errors="ignore")
        new_records = new_records.rename(columns={"row_hash_src": "row_hash"})

        expired_ids = changed_users["user_id"].tolist()
        logger.info(
            "SCD2 delta: %d new, %d changed (%d to expire)",
            len(new_users),
            len(changed_users),
            len(expired_ids),
        )
        return new_records, expired_ids

    # ------------------------------------------------------------------
    # Load
    # ------------------------------------------------------------------

    def close_expired_records(self, expired_ids: list[str]) -> None:
        """Set is_current=false and valid_to=today for changed records."""
        if not expired_ids:
            return
        placeholders = ", ".join(f"'{uid}'" for uid in expired_ids)
        with self.target_engine.begin() as conn:
            conn.execute(
                text(
                    f"""
                    UPDATE {self.DIM_TABLE}
                    SET is_current = false,
                        valid_to   = :today
                    WHERE user_id IN ({placeholders})
                      AND is_current = true
                    """
                ),
                {"today": date.today()},
            )
        logger.info("Closed %d expired dimension records", len(expired_ids))

    def insert_new_records(self, new_df: pd.DataFrame) -> int:
        """Append fresh SCD2 records with is_current=true."""
        if new_df.empty:
            return 0
        new_df = new_df.copy()
        new_df["is_current"] = True
        new_df["valid_from"] = date.today()
        new_df["valid_to"] = date(9999, 12, 31)
        new_df["etl_loaded_at"] = datetime.utcnow()
        new_df.to_sql(
            self.DIM_TABLE, self.target_engine, if_exists="append", index=False, method="multi"
        )
        logger.info("Inserted %d new dimension records", len(new_df))
        return len(new_df)

    # ------------------------------------------------------------------
    # Entrypoint
    # ------------------------------------------------------------------

    def run(self) -> dict:
        start = datetime.utcnow()
        try:
            source_df = self.extract_source()
            current_df = self.extract_current_dim()
            new_records, expired_ids = self.compute_deltas(source_df, current_df)
            self.close_expired_records(expired_ids)
            rows_inserted = self.insert_new_records(new_records)
            duration = (datetime.utcnow() - start).total_seconds()
            return {
                "status": "success",
                "rows_inserted": rows_inserted,
                "records_expired": len(expired_ids),
                "duration_secs": duration,
            }
        except Exception as exc:
            logger.error("users_pipeline failed: %s", exc, exc_info=True)
            raise
PYEOF

# ── inventory_pipeline.py ──────────────────────────────────────────────────────
cat << 'PYEOF' > data/pipeline_repo/inventory_pipeline.py
"""
Inventory daily snapshot pipeline.
Captures a daily point-in-time snapshot of warehouse inventory levels.
Uses delta detection to identify low-stock and out-of-stock SKUs.
Writes snapshots to the inventory_snapshots table for trend analysis.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass, field
from datetime import date, datetime
from typing import Optional

import pandas as pd
from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine

logger = logging.getLogger(__name__)

LOW_STOCK_THRESHOLD = 10
OUT_OF_STOCK_THRESHOLD = 0


@dataclass
class InventoryAlert:
    sku_id: str
    product_name: str
    warehouse_id: str
    quantity_on_hand: int
    alert_type: str  # "LOW_STOCK" | "OUT_OF_STOCK"
    snapshot_date: date = field(default_factory=date.today)


class InventorySnapshotPipeline:
    """
    Daily inventory snapshot pipeline.

    Reads the current inventory state, computes stock health metrics,
    flags anomalies, and appends a snapshot row per SKU per warehouse.
    Incremental delta detection avoids redundant snapshot rows when
    stock levels are unchanged.
    """

    SOURCE_TABLE = "inventory"
    SNAPSHOT_TABLE = "inventory_snapshots"
    ALERT_TABLE = "inventory_alerts"

    def __init__(self, source_conn: str, target_conn: str) -> None:
        self.source_engine: Engine = create_engine(source_conn, pool_pre_ping=True)
        self.target_engine: Engine = create_engine(target_conn, pool_pre_ping=True)

    def extract_inventory(self) -> pd.DataFrame:
        """Full inventory snapshot from the source system."""
        query = text(
            """
            SELECT
                sku_id,
                product_name,
                warehouse_id,
                quantity_on_hand,
                reorder_point,
                unit_cost_usd,
                last_received_at,
                last_shipped_at
            FROM inventory
            WHERE is_active = true
            """
        )
        with self.source_engine.connect() as conn:
            df = pd.read_sql(query, conn)
        logger.info("Extracted %d inventory rows", len(df))
        return df

    def extract_last_snapshot(self) -> pd.DataFrame:
        """Yesterday's snapshot for delta comparison."""
        yesterday = (datetime.utcnow().date() - pd.Timedelta(days=1))
        query = text(
            f"""
            SELECT sku_id, warehouse_id, quantity_on_hand AS prev_quantity
            FROM {self.SNAPSHOT_TABLE}
            WHERE snapshot_date = :yesterday
            """
        )
        with self.target_engine.connect() as conn:
            return pd.read_sql(query, conn, params={"yesterday": yesterday})

    def transform(
        self, current_df: pd.DataFrame, last_df: pd.DataFrame
    ) -> tuple[pd.DataFrame, list[InventoryAlert]]:
        """Enrich snapshot with derived metrics and generate alerts."""
        df = current_df.copy()
        df["snapshot_date"] = date.today()
        df["etl_loaded_at"] = datetime.utcnow()
        df["stock_value_usd"] = (df["quantity_on_hand"] * df["unit_cost_usd"]).round(2)
        df["stock_status"] = "OK"
        df.loc[df["quantity_on_hand"] <= LOW_STOCK_THRESHOLD, "stock_status"] = "LOW_STOCK"
        df.loc[df["quantity_on_hand"] <= OUT_OF_STOCK_THRESHOLD, "stock_status"] = "OUT_OF_STOCK"

        # Delta: quantity_delta vs yesterday
        if not last_df.empty:
            df = df.merge(last_df, on=["sku_id", "warehouse_id"], how="left")
            df["quantity_delta"] = df["quantity_on_hand"] - df["prev_quantity"].fillna(0)
        else:
            df["quantity_delta"] = 0
        df = df.drop(columns=["prev_quantity"], errors="ignore")

        # Generate alerts
        alerts: list[InventoryAlert] = []
        for _, row in df[df["stock_status"] != "OK"].iterrows():
            alerts.append(
                InventoryAlert(
                    sku_id=row["sku_id"],
                    product_name=row["product_name"],
                    warehouse_id=row["warehouse_id"],
                    quantity_on_hand=int(row["quantity_on_hand"]),
                    alert_type=row["stock_status"],
                )
            )

        logger.info("Snapshot: %d rows, %d alerts", len(df), len(alerts))
        return df, alerts

    def load_snapshot(self, df: pd.DataFrame) -> int:
        df.to_sql(
            self.SNAPSHOT_TABLE,
            self.target_engine,
            if_exists="append",
            index=False,
            method="multi",
            chunksize=500,
        )
        return len(df)

    def load_alerts(self, alerts: list[InventoryAlert]) -> None:
        if not alerts:
            return
        alert_df = pd.DataFrame([vars(a) for a in alerts])
        alert_df.to_sql(
            self.ALERT_TABLE, self.target_engine, if_exists="append", index=False
        )
        logger.info("Persisted %d inventory alerts", len(alerts))

    def run(self) -> dict:
        start = datetime.utcnow()
        try:
            current = self.extract_inventory()
            last = self.extract_last_snapshot()
            snapshot_df, alerts = self.transform(current, last)
            rows = self.load_snapshot(snapshot_df)
            self.load_alerts(alerts)
            duration = (datetime.utcnow() - start).total_seconds()
            return {"status": "success", "snapshot_rows": rows, "alerts": len(alerts), "duration_secs": duration}
        except Exception as exc:
            logger.error("inventory_pipeline failed: %s", exc, exc_info=True)
            raise
PYEOF

# ── sessions_pipeline.py ──────────────────────────────────────────────────────
cat << 'PYEOF' > data/pipeline_repo/sessions_pipeline.py
"""
Sessions streaming window aggregation pipeline.
Processes raw clickstream events and aggregates them into user session metrics
using a 30-minute inactivity timeout to define session boundaries.
Outputs to the sessions_agg table consumed by the BI layer.
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta
from typing import Iterator

import pandas as pd
from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine

logger = logging.getLogger(__name__)

SESSION_TIMEOUT_MINUTES = 30
WINDOW_HOURS = 2  # process events from the last N hours


def _assign_session_ids(events: pd.DataFrame) -> pd.DataFrame:
    """
    Assign session IDs using a 30-minute inactivity gap rule.

    Within each user partition, events are ordered by event_timestamp.
    A new session starts whenever the gap to the previous event exceeds
    SESSION_TIMEOUT_MINUTES.  The session_id is a composite of user_id
    and the session start timestamp.
    """
    events = events.sort_values(["user_id", "event_timestamp"]).copy()
    events["prev_ts"] = events.groupby("user_id")["event_timestamp"].shift(1)
    events["gap_minutes"] = (
        events["event_timestamp"] - events["prev_ts"]
    ).dt.total_seconds() / 60

    events["is_new_session"] = (
        events["prev_ts"].isna()
        | (events["gap_minutes"] > SESSION_TIMEOUT_MINUTES)
    )
    events["session_seq"] = events.groupby("user_id")["is_new_session"].cumsum()
    events["session_id"] = (
        events["user_id"].astype(str)
        + "_"
        + events["session_seq"].astype(str)
    )
    return events.drop(columns=["prev_ts", "gap_minutes", "is_new_session", "session_seq"])


class SessionAggregationPipeline:
    """
    Micro-batch session aggregation over a sliding time window.

    Reads raw clickstream events, assigns session boundaries,
    and produces per-session aggregate metrics.
    """

    EVENTS_TABLE = "clickstream_events"
    OUTPUT_TABLE = "sessions_agg"

    def __init__(self, source_conn: str, target_conn: str) -> None:
        self.source_engine: Engine = create_engine(source_conn, pool_pre_ping=True)
        self.target_engine: Engine = create_engine(target_conn, pool_pre_ping=True)

    def extract_events(self, watermark: datetime) -> pd.DataFrame:
        """Extract raw clickstream events within the processing window."""
        query = text(
            f"""
            SELECT
                event_id,
                user_id,
                session_hint_id,
                event_type,
                page_url,
                referrer_url,
                device_type,
                geo_country,
                event_timestamp
            FROM {self.EVENTS_TABLE}
            WHERE event_timestamp >= :watermark
              AND event_timestamp <  :now
            ORDER BY user_id, event_timestamp
            """
        )
        with self.source_engine.connect() as conn:
            df = pd.read_sql(
                query, conn,
                params={"watermark": watermark, "now": datetime.utcnow()},
                parse_dates=["event_timestamp"],
            )
        logger.info("Extracted %d clickstream events", len(df))
        return df

    def transform(self, events: pd.DataFrame) -> pd.DataFrame:
        """Assign sessions and aggregate to session-level metrics."""
        if events.empty:
            return pd.DataFrame()

        events = _assign_session_ids(events)

        agg = (
            events.groupby("session_id")
            .agg(
                user_id=("user_id", "first"),
                session_start=("event_timestamp", "min"),
                session_end=("event_timestamp", "max"),
                total_events=("event_id", "count"),
                unique_pages=("page_url", "nunique"),
                device_type=("device_type", "first"),
                geo_country=("geo_country", "first"),
                has_referrer=("referrer_url", lambda x: x.notna().any()),
            )
            .reset_index()
        )

        agg["duration_seconds"] = (
            agg["session_end"] - agg["session_start"]
        ).dt.total_seconds().astype(int)
        agg["is_bounce"] = (agg["total_events"] == 1) & (agg["duration_seconds"] < 10)
        agg["etl_loaded_at"] = datetime.utcnow()

        logger.info("Aggregated %d sessions from %d events", len(agg), len(events))
        return agg

    def load(self, sessions: pd.DataFrame) -> int:
        if sessions.empty:
            return 0
        sessions.to_sql(
            self.OUTPUT_TABLE,
            self.target_engine,
            if_exists="append",
            index=False,
            method="multi",
            chunksize=1000,
        )
        return len(sessions)

    def run(self) -> dict:
        start = datetime.utcnow()
        watermark = start - timedelta(hours=WINDOW_HOURS)
        try:
            events = self.extract_events(watermark)
            sessions = self.transform(events)
            rows = self.load(sessions)
            duration = (datetime.utcnow() - start).total_seconds()
            return {"status": "success", "sessions": rows, "events": len(events), "duration_secs": duration}
        except Exception as exc:
            logger.error("sessions_pipeline failed: %s", exc, exc_info=True)
            raise
PYEOF

# ── metrics_pipeline.py ───────────────────────────────────────────────────────
cat << 'PYEOF' > data/pipeline_repo/metrics_pipeline.py
"""
KPI metrics computation pipeline with SLO tracking.
Computes daily business KPIs (GMV, DAU, Conversion Rate, Avg Order Value)
from warehouse tables and writes to the kpi_daily_metrics table.
Evaluates against SLO thresholds and emits breach events.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from typing import Any

import pandas as pd
from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine

logger = logging.getLogger(__name__)

KPI_DEFINITIONS: dict[str, dict[str, Any]] = {
    "gmv_usd": {
        "description": "Gross Merchandise Value in USD",
        "slo_min": 50_000.0,
        "alert_on": "below",
    },
    "daily_active_users": {
        "description": "Unique users with at least one session",
        "slo_min": 500,
        "alert_on": "below",
    },
    "conversion_rate_pct": {
        "description": "Orders / Sessions * 100",
        "slo_min": 2.0,
        "slo_max": 15.0,
        "alert_on": "both",
    },
    "avg_order_value_usd": {
        "description": "GMV / total orders",
        "slo_min": 30.0,
        "alert_on": "below",
    },
    "cart_abandonment_rate_pct": {
        "description": "Abandoned carts / total cart initiations * 100",
        "slo_max": 75.0,
        "alert_on": "above",
    },
}


@dataclass
class SLOBreach:
    kpi_name: str
    actual_value: float
    slo_threshold: float
    breach_type: str  # "below_min" | "above_max"
    metric_date: date


class MetricsPipeline:
    """
    Daily KPI computation pipeline.

    Reads from the warehouse layer (orders_fact, sessions_agg, dim_users),
    computes composite business metrics, evaluates SLO thresholds,
    and writes to kpi_daily_metrics with breach event logging.
    """

    def __init__(self, warehouse_conn: str) -> None:
        self.engine: Engine = create_engine(warehouse_conn, pool_pre_ping=True)

    def compute_gmv(self, metric_date: date) -> float:
        """Sum of total_amount for delivered/confirmed orders on metric_date."""
        result = self.engine.execute(
            text(
                """
                SELECT COALESCE(SUM(total_amount), 0.0) AS gmv
                FROM orders_fact
                WHERE order_date = :d
                  AND order_status IN ('confirmed', 'shipped', 'delivered')
                """
            ),
            {"d": metric_date},
        ).scalar()
        return float(result)

    def compute_dau(self, metric_date: date) -> int:
        """Count of unique users with at least one session on metric_date."""
        result = self.engine.execute(
            text(
                """
                SELECT COUNT(DISTINCT user_id) AS dau
                FROM sessions_agg
                WHERE DATE(session_start) = :d
                """
            ),
            {"d": metric_date},
        ).scalar()
        return int(result or 0)

    def compute_conversion_rate(self, metric_date: date, dau: int) -> float:
        """Orders / DAU * 100, guard against division by zero."""
        if dau == 0:
            return 0.0
        orders = self.engine.execute(
            text(
                """
                SELECT COUNT(*) FROM orders_fact
                WHERE order_date = :d AND status_code >= 1
                """
            ),
            {"d": metric_date},
        ).scalar()
        return round((float(orders) / dau) * 100, 4)

    def compute_aov(self, metric_date: date, gmv: float) -> float:
        """Average order value = GMV / total orders."""
        orders = self.engine.execute(
            text(
                "SELECT COUNT(*) FROM orders_fact WHERE order_date = :d AND status_code >= 1"
            ),
            {"d": metric_date},
        ).scalar()
        return round(gmv / orders, 2) if orders else 0.0

    def evaluate_slos(self, metrics: dict[str, float], metric_date: date) -> list[SLOBreach]:
        """Compare computed metrics against SLO thresholds and return breaches."""
        breaches: list[SLOBreach] = []
        for kpi, value in metrics.items():
            defn = KPI_DEFINITIONS.get(kpi, {})
            slo_min = defn.get("slo_min")
            slo_max = defn.get("slo_max")
            if slo_min is not None and value < slo_min:
                breaches.append(SLOBreach(kpi, value, slo_min, "below_min", metric_date))
            if slo_max is not None and value > slo_max:
                breaches.append(SLOBreach(kpi, value, slo_max, "above_max", metric_date))
        if breaches:
            logger.warning("SLO breaches detected: %d", len(breaches))
        return breaches

    def persist(self, metrics: dict[str, float], metric_date: date, breaches: list[SLOBreach]) -> None:
        row = {
            "metric_date": metric_date,
            "etl_loaded_at": datetime.utcnow(),
            "slo_breaches": len(breaches),
            **metrics,
        }
        pd.DataFrame([row]).to_sql(
            "kpi_daily_metrics", self.engine, if_exists="append", index=False
        )
        if breaches:
            breach_df = pd.DataFrame([vars(b) for b in breaches])
            breach_df.to_sql("slo_breach_events", self.engine, if_exists="append", index=False)

    def run(self, metric_date: date | None = None) -> dict:
        metric_date = metric_date or (datetime.utcnow().date() - timedelta(days=1))
        start = datetime.utcnow()
        try:
            gmv = self.compute_gmv(metric_date)
            dau = self.compute_dau(metric_date)
            conversion = self.compute_conversion_rate(metric_date, dau)
            aov = self.compute_aov(metric_date, gmv)

            metrics = {
                "gmv_usd": gmv,
                "daily_active_users": float(dau),
                "conversion_rate_pct": conversion,
                "avg_order_value_usd": aov,
            }

            breaches = self.evaluate_slos(metrics, metric_date)
            self.persist(metrics, metric_date, breaches)

            duration = (datetime.utcnow() - start).total_seconds()
            logger.info("metrics_pipeline SUCCESS for %s in %.2fs", metric_date, duration)
            return {"status": "success", "metrics": metrics, "breaches": len(breaches), "duration_secs": duration}
        except Exception as exc:
            logger.error("metrics_pipeline failed: %s", exc, exc_info=True)
            raise
PYEOF

# ── SQL files ─────────────────────────────────────────────────────────────────
cat << 'SQLEOF' > data/sql/orders_schema.sql
-- ============================================================================
-- Orders domain schema
-- Source-of-truth DDL for the orders pipeline
-- ============================================================================

CREATE TABLE IF NOT EXISTS orders (
    order_id           VARCHAR(36)    NOT NULL PRIMARY KEY,
    customer_id        VARCHAR(36)    NOT NULL,
    product_id         VARCHAR(36)    NOT NULL,
    order_status       VARCHAR(20)    NOT NULL CHECK (order_status IN
                         ('pending','confirmed','shipped','delivered','cancelled')),
    total_amount       NUMERIC(12,2)  NOT NULL CHECK (total_amount >= 0),
    currency           CHAR(3)        NOT NULL DEFAULT 'USD',
    shipping_address_id VARCHAR(36),
    created_at         TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at         TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_orders_customer  ON orders (customer_id);
CREATE INDEX IF NOT EXISTS idx_orders_updated   ON orders (updated_at);
CREATE INDEX IF NOT EXISTS idx_orders_status    ON orders (order_status);

-- Warehouse fact table (target of the orders ETL pipeline)
CREATE TABLE IF NOT EXISTS orders_fact (
    order_id            VARCHAR(36)   NOT NULL PRIMARY KEY,
    customer_id         VARCHAR(36)   NOT NULL,
    product_id          VARCHAR(36),
    order_status        VARCHAR(20),
    status_code         SMALLINT,
    total_amount        NUMERIC(12,2),
    currency            CHAR(3),
    is_high_value       BOOLEAN       DEFAULT FALSE,
    order_date          DATE,
    order_month         VARCHAR(7),
    shipping_address_id VARCHAR(36),
    created_at          TIMESTAMP,
    updated_at          TIMESTAMP,
    etl_loaded_at       TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS pipeline_state (
    pipeline_id     VARCHAR(64)  NOT NULL PRIMARY KEY,
    last_watermark  TIMESTAMP    NOT NULL
);

-- Staging table (transient; recreated each run)
CREATE TABLE IF NOT EXISTS stg_orders_tmp (LIKE orders_fact);
SQLEOF

cat << 'SQLEOF' > data/sql/users_schema.sql
-- ============================================================================
-- Users domain schema — SCD Type-2 dimension
-- PII notice: email, phone_number, date_of_birth are PII_HIGH
-- ============================================================================

CREATE TABLE IF NOT EXISTS users (
    user_id           VARCHAR(36)   NOT NULL PRIMARY KEY,
    full_name         VARCHAR(200),                       -- PII_MEDIUM
    email             VARCHAR(320)  NOT NULL UNIQUE,      -- PII_HIGH
    phone_number      VARCHAR(20),                        -- PII_HIGH
    date_of_birth     DATE,                               -- PII_HIGH
    address_id        VARCHAR(36),
    subscription_tier VARCHAR(20)   DEFAULT 'free'
                        CHECK (subscription_tier IN ('free','basic','premium','enterprise')),
    is_deleted        BOOLEAN       DEFAULT FALSE,
    created_at        TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at        TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- SCD Type-2 dimension table (target of users_pipeline)
CREATE TABLE IF NOT EXISTS dim_users (
    user_sk           SERIAL        PRIMARY KEY,          -- surrogate key
    user_id           VARCHAR(36)   NOT NULL,             -- natural key
    full_name         VARCHAR(200),
    email             VARCHAR(320),
    phone_number      VARCHAR(20),
    date_of_birth     DATE,
    address_id        VARCHAR(36),
    subscription_tier VARCHAR(20),
    row_hash          VARCHAR(32)   NOT NULL,
    is_current        BOOLEAN       NOT NULL DEFAULT TRUE,
    valid_from        DATE          NOT NULL,
    valid_to          DATE          NOT NULL DEFAULT '9999-12-31',
    etl_loaded_at     TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_dim_users_natural   ON dim_users (user_id, is_current);
CREATE INDEX IF NOT EXISTS idx_dim_users_valid_from ON dim_users (valid_from);
SQLEOF

cat << 'SQLEOF' > data/sql/analytics_views.sql
-- ============================================================================
-- Analytical layer views consumed by BI dashboards and ML feature store
-- These views depend on: orders_fact, dim_users, sessions_agg, inventory_snapshots
-- ============================================================================

-- Revenue by subscription tier (joins orders_fact -> dim_users SCD2)
CREATE OR REPLACE VIEW vw_revenue_by_tier AS
SELECT
    u.subscription_tier,
    DATE_TRUNC('month', o.order_date)      AS month,
    COUNT(DISTINCT o.order_id)             AS order_count,
    SUM(o.total_amount)                    AS gmv_usd,
    AVG(o.total_amount)                    AS avg_order_value,
    COUNT(DISTINCT o.customer_id)          AS unique_customers
FROM orders_fact o
JOIN dim_users u
    ON o.customer_id = u.user_id
   AND u.is_current = TRUE
WHERE o.status_code >= 1
GROUP BY 1, 2;

-- Daily funnel: sessions -> orders conversion
CREATE OR REPLACE VIEW vw_daily_funnel AS
WITH daily_sessions AS (
    SELECT
        DATE(session_start)      AS metric_date,
        COUNT(*)                 AS total_sessions,
        COUNT(DISTINCT user_id)  AS unique_users,
        SUM(CASE WHEN is_bounce THEN 1 ELSE 0 END) AS bounced_sessions
    FROM sessions_agg
    GROUP BY 1
),
daily_orders AS (
    SELECT
        order_date              AS metric_date,
        COUNT(*)                AS total_orders,
        SUM(total_amount)       AS gmv_usd
    FROM orders_fact
    WHERE status_code >= 1
    GROUP BY 1
)
SELECT
    s.metric_date,
    s.total_sessions,
    s.unique_users,
    s.bounced_sessions,
    ROUND(s.bounced_sessions * 100.0 / NULLIF(s.total_sessions, 0), 2) AS bounce_rate_pct,
    o.total_orders,
    o.gmv_usd,
    ROUND(o.total_orders * 100.0 / NULLIF(s.unique_users, 0), 4)       AS conversion_rate_pct
FROM daily_sessions s
LEFT JOIN daily_orders o USING (metric_date)
ORDER BY s.metric_date DESC;

-- Inventory health dashboard
CREATE OR REPLACE VIEW vw_inventory_health AS
SELECT
    snapshot_date,
    warehouse_id,
    COUNT(*)                                      AS total_skus,
    SUM(CASE WHEN stock_status = 'OK'          THEN 1 ELSE 0 END) AS healthy_skus,
    SUM(CASE WHEN stock_status = 'LOW_STOCK'   THEN 1 ELSE 0 END) AS low_stock_skus,
    SUM(CASE WHEN stock_status = 'OUT_OF_STOCK' THEN 1 ELSE 0 END) AS oos_skus,
    SUM(stock_value_usd)                          AS total_stock_value_usd
FROM inventory_snapshots
GROUP BY 1, 2
ORDER BY 1 DESC, 2;
SQLEOF

# ── YAML DAG files ────────────────────────────────────────────────────────────
cat << 'YAMLEOF' > data/dags/orders_dag.yml
dag_id: orders_incremental_etl
description: "Incremental orders ETL — MERGE strategy upsert from OLTP to warehouse"
schedule_interval: "0 * * * *"   # hourly
start_date: "2024-01-01"
catchup: false
max_active_runs: 1
default_args:
  owner: data-engineering
  retries: 3
  retry_delay_minutes: 5
  email_on_failure: true
  email: ["de-alerts@company.com"]

tasks:
  - task_id: validate_source_connection
    operator: PythonOperator
    python_callable: "ingestion.validators.check_source_conn"
    params:
      pipeline_id: orders

  - task_id: run_orders_pipeline
    operator: PythonOperator
    python_callable: "data.pipeline_repo.orders_pipeline.OrdersPipeline.run"
    depends_on: [validate_source_connection]
    params:
      source_conn: "{{ var.value.orders_source_conn }}"
      target_conn: "{{ var.value.warehouse_conn }}"
      lookback_hours: 24

  - task_id: run_dq_checks
    operator: GreatExpectationsOperator
    depends_on: [run_orders_pipeline]
    params:
      checkpoint_name: orders_fact_checkpoint
      fail_task_on_validation_failure: true

  - task_id: update_slo_metrics
    operator: PythonOperator
    python_callable: "monitoring.slo.record_run_outcome"
    depends_on: [run_dq_checks]
    trigger_rule: all_done

slo:
  success_rate_target_pct: 99.5
  max_duration_minutes: 5
  alert_channels: ["pagerduty", "slack-de-alerts"]
YAMLEOF

cat << 'YAMLEOF' > data/dags/users_dag.yml
dag_id: users_scd2_dimension
description: "Users SCD Type-2 dimension refresh — attribute change tracking"
schedule_interval: "0 2 * * *"   # daily at 02:00 UTC
start_date: "2024-01-01"
catchup: false
max_active_runs: 1
default_args:
  owner: data-engineering
  retries: 2
  retry_delay_minutes: 10
  email_on_failure: true

tasks:
  - task_id: extract_source_users
    operator: PythonOperator
    python_callable: "data.pipeline_repo.users_pipeline.UsersDimensionPipeline.extract_source"

  - task_id: compute_scd2_deltas
    operator: PythonOperator
    python_callable: "data.pipeline_repo.users_pipeline.UsersDimensionPipeline.compute_deltas"
    depends_on: [extract_source_users]

  - task_id: apply_scd2_changes
    operator: PythonOperator
    python_callable: "data.pipeline_repo.users_pipeline.UsersDimensionPipeline.run"
    depends_on: [compute_scd2_deltas]

  - task_id: pii_audit_scan
    operator: PythonOperator
    python_callable: "monitoring.pii.audit_pii_columns"
    depends_on: [apply_scd2_changes]
    params:
      table: dim_users
      pii_columns: ["email", "phone_number", "date_of_birth", "full_name"]

slo:
  success_rate_target_pct: 99.0
  max_duration_minutes: 30
YAMLEOF

cat << 'YAMLEOF' > data/dags/metrics_dag.yml
dag_id: daily_kpi_metrics
description: "Daily business KPI computation with SLO breach detection"
schedule_interval: "30 1 * * *"   # daily at 01:30 UTC (after orders + users complete)
start_date: "2024-01-01"
catchup: false
max_active_runs: 1
default_args:
  owner: analytics-engineering
  retries: 2
  retry_delay_minutes: 15

tasks:
  - task_id: wait_for_orders
    operator: ExternalTaskSensor
    external_dag_id: orders_incremental_etl
    external_task_id: update_slo_metrics
    timeout: 3600
    poke_interval: 60

  - task_id: wait_for_users
    operator: ExternalTaskSensor
    external_dag_id: users_scd2_dimension
    external_task_id: pii_audit_scan
    timeout: 3600

  - task_id: compute_kpis
    operator: PythonOperator
    python_callable: "data.pipeline_repo.metrics_pipeline.MetricsPipeline.run"
    depends_on: [wait_for_orders, wait_for_users]
    params:
      warehouse_conn: "{{ var.value.warehouse_conn }}"

  - task_id: publish_to_dashboard
    operator: PythonOperator
    python_callable: "reporting.publisher.push_kpis_to_metabase"
    depends_on: [compute_kpis]

slo:
  success_rate_target_pct: 99.0
  max_duration_minutes: 60
  kpi_slos:
    gmv_usd_min: 50000
    dau_min: 500
    conversion_rate_pct_min: 2.0
    conversion_rate_pct_max: 15.0
YAMLEOF

# ── dbt manifest.json ─────────────────────────────────────────────────────────
cat << 'JEOF' > data/dbt_project/manifest.json
{
  "metadata": {
    "dbt_schema_version": "https://schemas.getdbt.com/dbt/manifest/v9.json",
    "dbt_version": "1.7.0",
    "generated_at": "2024-03-15T02:00:00.000000Z",
    "invocation_id": "pm-manifest-v1",
    "env": {}
  },
  "nodes": {
    "model.pipelinemind.stg_orders": {
      "unique_id": "model.pipelinemind.stg_orders",
      "resource_type": "model",
      "name": "stg_orders",
      "description": "Staged orders from OLTP source. Applies type coercions and drops nulls on order_id/customer_id.",
      "path": "staging/stg_orders.sql",
      "schema": "staging",
      "database": "warehouse",
      "alias": "stg_orders",
      "columns": {
        "order_id":   {"name": "order_id",   "description": "Primary key — UUID",         "data_type": "varchar"},
        "customer_id":{"name": "customer_id","description": "FK to dim_users.user_id",    "data_type": "varchar"},
        "product_id": {"name": "product_id", "description": "FK to dim_products",         "data_type": "varchar"},
        "total_amount":{"name":"total_amount","description":"Order total in USD",          "data_type": "numeric"},
        "status_code":{"name": "status_code","description": "Numeric status (0=pending)", "data_type": "smallint"},
        "order_date": {"name": "order_date", "description": "Calendar date of order",     "data_type": "date"}
      },
      "depends_on": {"nodes": []},
      "config": {"materialized": "view"},
      "tags": ["orders", "staging"],
      "meta": {"owner": "data-engineering", "slo_tier": "gold"}
    },
    "model.pipelinemind.orders_fact": {
      "unique_id": "model.pipelinemind.orders_fact",
      "resource_type": "model",
      "name": "orders_fact",
      "description": "Orders fact table. Incremental MERGE from stg_orders. Consumed by vw_revenue_by_tier and vw_daily_funnel.",
      "path": "marts/orders_fact.sql",
      "schema": "marts",
      "database": "warehouse",
      "alias": "orders_fact",
      "columns": {
        "order_id":       {"name":"order_id",       "description":"PK",                        "data_type":"varchar"},
        "customer_id":    {"name":"customer_id",    "description":"FK dim_users",              "data_type":"varchar"},
        "total_amount":   {"name":"total_amount",   "description":"USD order total",           "data_type":"numeric"},
        "is_high_value":  {"name":"is_high_value",  "description":"total_amount > 1000",       "data_type":"boolean"},
        "order_date":     {"name":"order_date",     "description":"Date partition key",        "data_type":"date"},
        "etl_loaded_at":  {"name":"etl_loaded_at",  "description":"ETL load timestamp",        "data_type":"timestamp"}
      },
      "depends_on": {"nodes": ["model.pipelinemind.stg_orders"]},
      "config": {"materialized": "incremental", "unique_key": "order_id", "incremental_strategy": "merge"},
      "tags": ["orders", "fact", "finance"],
      "meta": {"owner": "data-engineering", "slo_tier": "gold", "downstream_bi": true}
    },
    "model.pipelinemind.dim_users": {
      "unique_id": "model.pipelinemind.dim_users",
      "resource_type": "model",
      "name": "dim_users",
      "description": "SCD Type-2 users dimension. Tracks historical changes to email, phone_number, subscription_tier, address_id.",
      "path": "dims/dim_users.sql",
      "schema": "dims",
      "database": "warehouse",
      "alias": "dim_users",
      "columns": {
        "user_sk":          {"name":"user_sk",          "description":"Surrogate key",     "data_type":"integer"},
        "user_id":          {"name":"user_id",          "description":"Natural key",       "data_type":"varchar"},
        "email":            {"name":"email",            "description":"PII_HIGH — user email", "data_type":"varchar", "meta":{"pii_class":"PII_HIGH"}},
        "phone_number":     {"name":"phone_number",     "description":"PII_HIGH",          "data_type":"varchar",   "meta":{"pii_class":"PII_HIGH"}},
        "date_of_birth":    {"name":"date_of_birth",    "description":"PII_HIGH",          "data_type":"date",      "meta":{"pii_class":"PII_HIGH"}},
        "full_name":        {"name":"full_name",        "description":"PII_MEDIUM",        "data_type":"varchar",   "meta":{"pii_class":"PII_MEDIUM"}},
        "subscription_tier":{"name":"subscription_tier","description":"User plan tier",   "data_type":"varchar"},
        "is_current":       {"name":"is_current",      "description":"Active SCD2 flag",  "data_type":"boolean"},
        "valid_from":       {"name":"valid_from",       "description":"SCD2 effective from","data_type":"date"},
        "valid_to":         {"name":"valid_to",         "description":"SCD2 expiry date",  "data_type":"date"}
      },
      "depends_on": {"nodes": []},
      "config": {"materialized": "incremental", "unique_key": "user_sk", "incremental_strategy": "merge"},
      "tags": ["users", "dimension", "pii"],
      "meta": {"owner": "data-engineering", "pii": true, "slo_tier": "gold"}
    },
    "model.pipelinemind.sessions_agg": {
      "unique_id": "model.pipelinemind.sessions_agg",
      "resource_type": "model",
      "name": "sessions_agg",
      "description": "Per-session aggregation of clickstream events. Session boundary: 30-min inactivity gap. Consumed by vw_daily_funnel and ML feature store.",
      "path": "marts/sessions_agg.sql",
      "schema": "marts",
      "database": "warehouse",
      "alias": "sessions_agg",
      "columns": {
        "session_id":      {"name":"session_id",       "description":"user_id + session_seq composite key","data_type":"varchar"},
        "user_id":         {"name":"user_id",          "description":"FK dim_users natural key",            "data_type":"varchar"},
        "session_start":   {"name":"session_start",    "description":"First event timestamp",              "data_type":"timestamp"},
        "session_end":     {"name":"session_end",      "description":"Last event timestamp",               "data_type":"timestamp"},
        "duration_seconds":{"name":"duration_seconds", "description":"session_end - session_start",         "data_type":"integer"},
        "total_events":    {"name":"total_events",     "description":"Count of clickstream events",        "data_type":"integer"},
        "unique_pages":    {"name":"unique_pages",     "description":"Count of distinct page_url values",  "data_type":"integer"},
        "is_bounce":       {"name":"is_bounce",        "description":"true if total_events=1 and duration<10s","data_type":"boolean"}
      },
      "depends_on": {"nodes": []},
      "config": {"materialized": "incremental", "unique_key": "session_id"},
      "tags": ["sessions", "clickstream", "mart"],
      "meta": {"owner": "analytics-engineering", "downstream_ml": true}
    },
    "model.pipelinemind.vw_revenue_by_tier": {
      "unique_id": "model.pipelinemind.vw_revenue_by_tier",
      "resource_type": "model",
      "name": "vw_revenue_by_tier",
      "description": "Revenue breakdown by subscription tier per month. Joins orders_fact to dim_users (is_current=true). Primary BI dashboard source.",
      "path": "reporting/vw_revenue_by_tier.sql",
      "schema": "reporting",
      "database": "warehouse",
      "alias": "vw_revenue_by_tier",
      "columns": {
        "subscription_tier":{"name":"subscription_tier","description":"User plan tier",       "data_type":"varchar"},
        "month":            {"name":"month",            "description":"Truncated to month",   "data_type":"date"},
        "gmv_usd":          {"name":"gmv_usd",          "description":"Gross merchandise value","data_type":"numeric"},
        "order_count":      {"name":"order_count",      "description":"Total confirmed orders","data_type":"integer"},
        "unique_customers": {"name":"unique_customers", "description":"Distinct customer count","data_type":"integer"}
      },
      "depends_on": {"nodes": ["model.pipelinemind.orders_fact","model.pipelinemind.dim_users"]},
      "config": {"materialized": "view"},
      "tags": ["finance", "bi", "reporting"],
      "meta": {"owner": "analytics-engineering", "downstream_bi": true}
    }
  },
  "sources": {},
  "exposures": {
    "exposure.pipelinemind.revenue_dashboard": {
      "name": "revenue_dashboard",
      "description": "Metabase Revenue by Tier dashboard consuming vw_revenue_by_tier",
      "type": "dashboard",
      "depends_on": {"nodes": ["model.pipelinemind.vw_revenue_by_tier"]},
      "owner": {"name": "BI Team", "email": "bi@company.com"}
    },
    "exposure.pipelinemind.ml_feature_store": {
      "name": "ml_feature_store",
      "description": "ML feature store consuming sessions_agg for user propensity model",
      "type": "ml",
      "depends_on": {"nodes": ["model.pipelinemind.sessions_agg"]},
      "owner": {"name": "ML Platform Team", "email": "mlplatform@company.com"}
    }
  }
}
JEOF

# ── dbt catalog.json ───────────────────────────────────────────────────────────
cat << 'JEOF' > data/dbt_project/catalog.json
{
  "metadata": {
    "dbt_schema_version": "https://schemas.getdbt.com/dbt/catalog/v1.json",
    "dbt_version": "1.7.0",
    "generated_at": "2024-03-15T02:05:00.000000Z"
  },
  "nodes": {
    "model.pipelinemind.orders_fact": {
      "unique_id": "model.pipelinemind.orders_fact",
      "metadata": {"type": "table", "schema": "marts", "name": "orders_fact", "rows": 2847293, "bytes": 524288000},
      "columns": {
        "order_id":      {"type": "character varying(36)", "index": 1, "name": "order_id"},
        "customer_id":   {"type": "character varying(36)", "index": 2, "name": "customer_id"},
        "total_amount":  {"type": "numeric(12,2)",          "index": 3, "name": "total_amount"},
        "is_high_value": {"type": "boolean",                "index": 4, "name": "is_high_value"},
        "order_date":    {"type": "date",                   "index": 5, "name": "order_date"},
        "status_code":   {"type": "smallint",               "index": 6, "name": "status_code"},
        "etl_loaded_at": {"type": "timestamp",              "index": 7, "name": "etl_loaded_at"}
      },
      "stats": {"has_stats": true, "row_count": {"value": 2847293}, "bytes": {"value": 524288000}}
    },
    "model.pipelinemind.dim_users": {
      "unique_id": "model.pipelinemind.dim_users",
      "metadata": {"type": "table", "schema": "dims", "name": "dim_users", "rows": 185432, "bytes": 62914560},
      "columns": {
        "user_sk":          {"type": "integer",                  "index": 1},
        "user_id":          {"type": "character varying(36)",    "index": 2},
        "email":            {"type": "character varying(320)",   "index": 3},
        "phone_number":     {"type": "character varying(20)",    "index": 4},
        "date_of_birth":    {"type": "date",                     "index": 5},
        "full_name":        {"type": "character varying(200)",   "index": 6},
        "subscription_tier":{"type": "character varying(20)",    "index": 7},
        "is_current":       {"type": "boolean",                  "index": 8},
        "valid_from":       {"type": "date",                     "index": 9},
        "valid_to":         {"type": "date",                     "index": 10}
      }
    }
  }
}
JEOF

# ── Catalogue / PII / Lineage fixtures ────────────────────────────────────────
cat << 'JEOF' > data/catalogue/tables_metadata.json
[
  {"table_id":"t001","table_name":"orders_fact","schema":"marts","description":"Orders fact table — incremental MERGE from OLTP","domain":"finance","pii_flag":false,"tags":["orders","finance","gold"],"row_count":2847293},
  {"table_id":"t002","table_name":"dim_users","schema":"dims","description":"SCD Type-2 users dimension with historical attribute tracking","domain":"users","pii_flag":true,"tags":["users","dimension","pii","gold"],"row_count":185432},
  {"table_id":"t003","table_name":"sessions_agg","schema":"marts","description":"Per-session aggregation from clickstream — 30-min inactivity boundary","domain":"product","pii_flag":false,"tags":["sessions","clickstream","silver"],"row_count":9234811},
  {"table_id":"t004","table_name":"inventory_snapshots","schema":"ops","description":"Daily inventory snapshot per SKU per warehouse","domain":"operations","pii_flag":false,"tags":["inventory","snapshot","silver"],"row_count":450000},
  {"table_id":"t005","table_name":"stg_orders","schema":"staging","description":"Staged orders view — type coercions applied","domain":"finance","pii_flag":false,"tags":["staging","orders"],"row_count":0},
  {"table_id":"t006","table_name":"vw_revenue_by_tier","schema":"reporting","description":"Revenue breakdown by subscription tier per month — primary BI view","domain":"finance","pii_flag":false,"tags":["reporting","bi","revenue"],"row_count":0},
  {"table_id":"t007","table_name":"kpi_daily_metrics","schema":"reporting","description":"Daily KPI metrics: GMV, DAU, conversion rate, AOV","domain":"finance","pii_flag":false,"tags":["kpi","metrics","reporting"],"row_count":365},
  {"table_id":"t008","table_name":"clickstream_events","schema":"raw","description":"Raw clickstream events from web/mobile clients","domain":"product","pii_flag":false,"tags":["raw","clickstream","bronze"],"row_count":84729312}
]
JEOF

cat << 'JEOF' > data/catalogue/pii_registry.json
[
  {"table_name":"dim_users","column_name":"email",         "pii_class":"PII_HIGH",   "sensitivity_level":"high",   "data_type":"varchar","retention_days":730},
  {"table_name":"dim_users","column_name":"phone_number",  "pii_class":"PII_HIGH",   "sensitivity_level":"high",   "data_type":"varchar","retention_days":730},
  {"table_name":"dim_users","column_name":"date_of_birth", "pii_class":"PII_HIGH",   "sensitivity_level":"high",   "data_type":"date",   "retention_days":730},
  {"table_name":"dim_users","column_name":"full_name",     "pii_class":"PII_MEDIUM", "sensitivity_level":"medium", "data_type":"varchar","retention_days":1095},
  {"table_name":"orders_fact","column_name":"customer_id", "pii_class":"PII_LOW",    "sensitivity_level":"low",    "data_type":"varchar","retention_days":2555},
  {"table_name":"clickstream_events","column_name":"user_id","pii_class":"PII_LOW",  "sensitivity_level":"low",    "data_type":"varchar","retention_days":365}
]
JEOF

cat << 'JEOF' > data/catalogue/lineage_edges.json
[
  {"source_table":"clickstream_events","source_column":"user_id",      "target_table":"sessions_agg",       "target_column":"user_id",       "transformation":"direct","pipeline_id":"sessions"},
  {"source_table":"sessions_agg",      "source_column":"session_id",   "target_table":"vw_daily_funnel",    "target_column":"session_id",    "transformation":"aggregation","pipeline_id":"metrics"},
  {"source_table":"orders_fact",       "source_column":"order_id",     "target_table":"vw_revenue_by_tier", "target_column":"order_id",      "transformation":"join","pipeline_id":"metrics"},
  {"source_table":"orders_fact",       "source_column":"customer_id",  "target_table":"vw_revenue_by_tier", "target_column":"customer_id",   "transformation":"join","pipeline_id":"metrics"},
  {"source_table":"dim_users",         "source_column":"user_id",      "target_table":"vw_revenue_by_tier", "target_column":"user_id",       "transformation":"join","pipeline_id":"metrics"},
  {"source_table":"dim_users",         "source_column":"subscription_tier","target_table":"vw_revenue_by_tier","target_column":"subscription_tier","transformation":"direct","pipeline_id":"metrics"},
  {"source_table":"stg_orders",        "source_column":"order_id",     "target_table":"orders_fact",        "target_column":"order_id",      "transformation":"merge","pipeline_id":"orders"},
  {"source_table":"sessions_agg",      "source_column":"user_id",      "target_table":"kpi_daily_metrics",  "target_column":"dau",           "transformation":"count_distinct","pipeline_id":"metrics"},
  {"source_table":"orders_fact",       "source_column":"total_amount", "target_table":"kpi_daily_metrics",  "target_column":"gmv_usd",       "transformation":"sum","pipeline_id":"metrics"}
]
JEOF

# ── Run logs (30-day synthetic history) ───────────────────────────────────────
python3 -c "
import json, random, uuid
from datetime import datetime, timedelta

statuses = ['success','success','success','success','failed']
pipelines = ['orders','users','inventory','sessions','metrics']
runs = []
base = datetime(2024,2,14,1,0,0)
for d in range(30):
    for p in pipelines:
        status = random.choice(statuses)
        dur = random.uniform(45,280) if status=='success' else random.uniform(5,60)
        runs.append({
            'run_id': str(uuid.uuid4()),
            'pipeline_id': p,
            'status': status,
            'start_time': (base + timedelta(days=d, minutes=random.randint(0,30))).isoformat(),
            'duration_secs': round(dur,2),
            'error_message': 'Connection timeout to source DB' if status=='failed' else None,
            'slo_met': status=='success' and dur < 300
        })
print(json.dumps(runs, indent=2))
" > data/run_logs/pipeline_runs.json

# ── Schema snapshots ──────────────────────────────────────────────────────────
cat << 'JEOF' > data/schema_snapshots/baseline.json
{
  "snapshot_id": "snap_baseline_001",
  "captured_at": "2024-03-15T02:00:00Z",
  "tables": {
    "orders_fact": {
      "columns": [
        {"name":"order_id",       "type":"varchar(36)",  "nullable":false},
        {"name":"customer_id",    "type":"varchar(36)",  "nullable":false},
        {"name":"product_id",     "type":"varchar(36)",  "nullable":true},
        {"name":"total_amount",   "type":"numeric(12,2)","nullable":false},
        {"name":"is_high_value",  "type":"boolean",      "nullable":true},
        {"name":"order_date",     "type":"date",         "nullable":true},
        {"name":"status_code",    "type":"smallint",     "nullable":true},
        {"name":"etl_loaded_at",  "type":"timestamp",    "nullable":false}
      ]
    },
    "dim_users": {
      "columns": [
        {"name":"user_sk",          "type":"integer",       "nullable":false},
        {"name":"user_id",          "type":"varchar(36)",   "nullable":false},
        {"name":"email",            "type":"varchar(320)",  "nullable":false},
        {"name":"phone_number",     "type":"varchar(20)",   "nullable":true},
        {"name":"date_of_birth",    "type":"date",          "nullable":true},
        {"name":"full_name",        "type":"varchar(200)",  "nullable":true},
        {"name":"subscription_tier","type":"varchar(20)",   "nullable":true},
        {"name":"is_current",       "type":"boolean",       "nullable":false},
        {"name":"valid_from",       "type":"date",          "nullable":false},
        {"name":"valid_to",         "type":"date",          "nullable":false}
      ]
    },
    "sessions_agg": {
      "columns": [
        {"name":"session_id",       "type":"varchar(100)", "nullable":false},
        {"name":"user_id",          "type":"varchar(36)",  "nullable":false},
        {"name":"session_start",    "type":"timestamp",    "nullable":false},
        {"name":"session_end",      "type":"timestamp",    "nullable":true},
        {"name":"duration_seconds", "type":"integer",      "nullable":true},
        {"name":"total_events",     "type":"integer",      "nullable":false},
        {"name":"unique_pages",     "type":"integer",      "nullable":true},
        {"name":"is_bounce",        "type":"boolean",      "nullable":true}
      ]
    }
  }
}
JEOF

# ==============================================================================
# SECTION: DuckDB Schema + Seeder
# ==============================================================================
step "Writing DuckDB schema and seeder"

cat << 'SQLEOF' > db/schema.sql
-- ============================================================================
-- PipelineMind DuckDB metadata store schema
-- ============================================================================

CREATE TABLE IF NOT EXISTS catalogue_tables (
    table_id         VARCHAR PRIMARY KEY,
    table_name       VARCHAR NOT NULL UNIQUE,
    schema_name      VARCHAR,
    description      TEXT,
    domain           VARCHAR,
    pii_flag         BOOLEAN DEFAULT FALSE,
    tags             VARCHAR[],
    row_count        BIGINT DEFAULT 0,
    created_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS catalogue_columns (
    column_id        VARCHAR PRIMARY KEY,
    table_id         VARCHAR NOT NULL REFERENCES catalogue_tables(table_id),
    column_name      VARCHAR NOT NULL,
    data_type        VARCHAR,
    pii_class        VARCHAR,          -- NULL | PII_LOW | PII_MEDIUM | PII_HIGH
    nullable         BOOLEAN DEFAULT TRUE,
    description      TEXT,
    retention_days   INTEGER
);

CREATE TABLE IF NOT EXISTS lineage_edges (
    edge_id          VARCHAR PRIMARY KEY,
    source_table     VARCHAR NOT NULL,
    source_column    VARCHAR,
    target_table     VARCHAR NOT NULL,
    target_column    VARCHAR,
    transformation   VARCHAR,
    pipeline_id      VARCHAR,
    created_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS pipeline_runs (
    run_id           VARCHAR PRIMARY KEY,
    pipeline_id      VARCHAR NOT NULL,
    status           VARCHAR NOT NULL,
    start_time       TIMESTAMP,
    duration_secs    DOUBLE,
    error_message    TEXT,
    slo_met          BOOLEAN DEFAULT TRUE,
    created_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS slo_definitions (
    slo_id           VARCHAR PRIMARY KEY,
    pipeline_id      VARCHAR NOT NULL UNIQUE,
    metric_name      VARCHAR NOT NULL,
    target_value     DOUBLE NOT NULL,
    comparison       VARCHAR NOT NULL,   -- "gte" | "lte" | "eq"
    window_days      INTEGER DEFAULT 7
);

CREATE TABLE IF NOT EXISTS schema_snapshots (
    snapshot_id      VARCHAR PRIMARY KEY,
    table_id         VARCHAR REFERENCES catalogue_tables(table_id),
    table_name       VARCHAR NOT NULL,
    columns_json     TEXT NOT NULL,     -- JSON array of column descriptors
    captured_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
SQLEOF

cat << 'PYEOF' > db/seeder.py
"""
DuckDB metadata store seeder.
Reads synthetic JSON fixtures and populates all 6 metadata tables.
Safe to re-run (uses INSERT OR REPLACE / ON CONFLICT DO UPDATE).
"""
from __future__ import annotations

import hashlib
import json
import logging
import sys
from pathlib import Path

import duckdb

# Allow running from project root
sys.path.insert(0, str(Path(__file__).parent.parent))
from config import settings

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger(__name__)

FIXTURES = Path(__file__).parent.parent / "data"


def _uid(*parts: str) -> str:
    return hashlib.sha256("|".join(parts).encode()).hexdigest()[:16]


def seed_tables(con: duckdb.DuckDBPyConnection) -> int:
    rows = json.loads((FIXTURES / "catalogue" / "tables_metadata.json").read_text())
    count = 0
    for r in rows:
        con.execute(
            """
            INSERT OR REPLACE INTO catalogue_tables
                (table_id, table_name, schema_name, description, domain, pii_flag, tags, row_count)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [r["table_id"], r["table_name"], r.get("schema"), r.get("description"),
             r.get("domain"), r.get("pii_flag", False), r.get("tags", []), r.get("row_count", 0)],
        )
        count += 1
    logger.info("Seeded %d catalogue tables", count)
    return count


def seed_columns(con: duckdb.DuckDBPyConnection) -> int:
    pii_rows = json.loads((FIXTURES / "catalogue" / "pii_registry.json").read_text())
    tables = {r["table_name"]: r["table_id"] for r in
              json.loads((FIXTURES / "catalogue" / "tables_metadata.json").read_text())}

    count = 0
    for r in pii_rows:
        table_id = tables.get(r["table_name"])
        if not table_id:
            continue
        col_id = _uid(r["table_name"], r["column_name"])
        con.execute(
            """
            INSERT OR REPLACE INTO catalogue_columns
                (column_id, table_id, column_name, data_type, pii_class, retention_days)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [col_id, table_id, r["column_name"], r.get("data_type"), r.get("pii_class"), r.get("retention_days")],
        )
        count += 1
    logger.info("Seeded %d PII columns", count)
    return count


def seed_lineage(con: duckdb.DuckDBPyConnection) -> int:
    rows = json.loads((FIXTURES / "catalogue" / "lineage_edges.json").read_text())
    count = 0
    for r in rows:
        edge_id = _uid(r["source_table"], r.get("source_column", ""), r["target_table"], r.get("target_column", ""))
        con.execute(
            """
            INSERT OR REPLACE INTO lineage_edges
                (edge_id, source_table, source_column, target_table, target_column, transformation, pipeline_id)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [edge_id, r["source_table"], r.get("source_column"), r["target_table"],
             r.get("target_column"), r.get("transformation"), r.get("pipeline_id")],
        )
        count += 1
    logger.info("Seeded %d lineage edges", count)
    return count


def seed_pipeline_runs(con: duckdb.DuckDBPyConnection) -> int:
    rows = json.loads((FIXTURES / "run_logs" / "pipeline_runs.json").read_text())
    count = 0
    for r in rows:
        con.execute(
            """
            INSERT OR REPLACE INTO pipeline_runs
                (run_id, pipeline_id, status, start_time, duration_secs, error_message, slo_met)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [r["run_id"], r["pipeline_id"], r["status"], r.get("start_time"),
             r.get("duration_secs"), r.get("error_message"), r.get("slo_met", True)],
        )
        count += 1
    logger.info("Seeded %d pipeline runs", count)
    return count


def seed_slo_definitions(con: duckdb.DuckDBPyConnection) -> int:
    definitions = [
        ("slo_orders",    "orders",    "success_rate_pct", 99.5, "gte", 7),
        ("slo_users",     "users",     "success_rate_pct", 99.0, "gte", 7),
        ("slo_inventory", "inventory", "success_rate_pct", 98.0, "gte", 7),
        ("slo_sessions",  "sessions",  "success_rate_pct", 99.0, "gte", 7),
        ("slo_metrics",   "metrics",   "success_rate_pct", 99.0, "gte", 7),
    ]
    for slo_id, pipeline_id, metric, target, comparison, window in definitions:
        con.execute(
            """
            INSERT OR REPLACE INTO slo_definitions
                (slo_id, pipeline_id, metric_name, target_value, comparison, window_days)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [slo_id, pipeline_id, metric, target, comparison, window],
        )
    logger.info("Seeded %d SLO definitions", len(definitions))
    return len(definitions)


def seed_schema_snapshots(con: duckdb.DuckDBPyConnection) -> int:
    snapshot = json.loads((FIXTURES / "schema_snapshots" / "baseline.json").read_text())
    tables = {r["table_name"]: r["table_id"] for r in
              json.loads((FIXTURES / "catalogue" / "tables_metadata.json").read_text())}

    count = 0
    for table_name, table_data in snapshot["tables"].items():
        table_id = tables.get(table_name)
        snap_id = _uid(snapshot["snapshot_id"], table_name)
        con.execute(
            """
            INSERT OR REPLACE INTO schema_snapshots
                (snapshot_id, table_id, table_name, columns_json, captured_at)
            VALUES (?, ?, ?, ?, ?)
            """,
            [snap_id, table_id, table_name,
             json.dumps(table_data["columns"]), snapshot["captured_at"]],
        )
        count += 1
    logger.info("Seeded %d schema snapshots", count)
    return count


def main() -> None:
    db_path = settings.duckdb_path
    db_path.parent.mkdir(parents=True, exist_ok=True)

    logger.info("Connecting to DuckDB at %s", db_path)
    con = duckdb.connect(str(db_path))

    schema_sql = (Path(__file__).parent / "schema.sql").read_text()
    con.executescript(schema_sql)
    logger.info("Schema applied")

    seed_tables(con)
    seed_columns(con)
    seed_lineage(con)
    seed_pipeline_runs(con)
    seed_slo_definitions(con)
    seed_schema_snapshots(con)

    # Verify
    for tbl in ["catalogue_tables","catalogue_columns","lineage_edges","pipeline_runs","slo_definitions","schema_snapshots"]:
        n = con.execute(f"SELECT COUNT(*) FROM {tbl}").fetchone()[0]
        logger.info("  %-30s  %d rows", tbl, n)

    con.close()
    logger.info("DuckDB seeding complete: %s", db_path)


if __name__ == "__main__":
    main()
PYEOF

# ==============================================================================
# SECTION: Ingestion — Chunkers
# ==============================================================================
step "Writing ingestion modules"

cat << 'PYEOF' > ingestion/chunkers/ast_chunker.py
"""
AST-based Python chunker using tree-sitter.
Extracts function/method/class boundaries as independent chunks.
Falls back to whole-file chunking if tree-sitter is unavailable.
"""
from __future__ import annotations

import hashlib
import logging
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

try:
    import tree_sitter_python as tspython
    from tree_sitter import Language, Node, Parser

    _PY_LANG = Language(tspython.language())
    try:
        _PARSER: Optional[Parser] = Parser(_PY_LANG)
    except TypeError:
        _PARSER = Parser()
        _PARSER.set_language(_PY_LANG)
    _TREE_SITTER_OK = True
except Exception as _e:
    _PARSER = None
    _TREE_SITTER_OK = False
    logger.warning("tree-sitter unavailable (%s) — using regex fallback", _e)


@dataclass
class CodeChunk:
    chunk_id: str
    source_file: str
    chunk_type: str          # function | method | class | module
    chunk_index: int
    language: str = "python"
    raw_code: str = ""
    summary: str = ""        # filled later by SummaryGenerator
    function_name: Optional[str] = None
    class_name: Optional[str] = None
    decorators: list[str] = field(default_factory=list)
    return_type: Optional[str] = None
    docstring: Optional[str] = None
    line_start: int = 0
    line_end: int = 0
    pipeline_name: str = ""
    pii_flag: bool = False
    tags: list[str] = field(default_factory=list)
    git_commit_hash: str = ""
    content_hash: str = ""
    source_type: str = "python"

    def __post_init__(self) -> None:
        if not self.content_hash:
            self.content_hash = hashlib.sha256(self.raw_code.encode()).hexdigest()[:16]
        if not self.chunk_id:
            self.chunk_id = hashlib.sha256(
                f"{self.source_file}:{self.chunk_index}".encode()
            ).hexdigest()


class ASTChunker:
    """Chunks .py files at function/class boundaries via tree-sitter."""

    def chunk(self, file_path: Path, git_commit_hash: str = "") -> list[CodeChunk]:
        source = file_path.read_text(encoding="utf-8")
        pipeline_name = file_path.stem

        if _TREE_SITTER_OK and _PARSER:
            return self._tree_sitter_chunk(source, str(file_path), pipeline_name, git_commit_hash)
        return self._regex_fallback(source, str(file_path), pipeline_name, git_commit_hash)

    # ── tree-sitter path ──────────────────────────────────────────────────────

    def _tree_sitter_chunk(
        self, source: str, source_file: str, pipeline_name: str, git_commit_hash: str
    ) -> list[CodeChunk]:
        src_bytes = source.encode("utf-8")
        tree = _PARSER.parse(src_bytes)
        chunks: list[CodeChunk] = []
        idx = 0

        for node in tree.root_node.children:
            if node.type == "function_definition":
                chunks.append(self._fn_chunk(node, src_bytes, source_file, idx, pipeline_name, git_commit_hash))
                idx += 1
            elif node.type == "class_definition":
                class_chunks = self._class_chunks(node, src_bytes, source_file, idx, pipeline_name, git_commit_hash)
                chunks.extend(class_chunks)
                idx += len(class_chunks)

        if not chunks:
            chunks.append(self._module_chunk(source, source_file, pipeline_name, git_commit_hash))
        return chunks

    def _fn_chunk(self, node: "Node", src: bytes, source_file: str,
                  idx: int, pipeline: str, git_hash: str) -> CodeChunk:
        raw = src[node.start_byte:node.end_byte].decode("utf-8")
        fn_name = self._child_text(node, "identifier", src)
        return CodeChunk(
            chunk_id=hashlib.sha256(f"{source_file}:{idx}".encode()).hexdigest(),
            source_file=source_file,
            chunk_type="function",
            chunk_index=idx,
            raw_code=raw,
            function_name=fn_name,
            decorators=self._decorators(node, src),
            return_type=self._return_type(node, src),
            docstring=self._docstring(node, src),
            line_start=node.start_point[0] + 1,
            line_end=node.end_point[0] + 1,
            pipeline_name=pipeline,
            git_commit_hash=git_hash,
        )

    def _class_chunks(self, node: "Node", src: bytes, source_file: str,
                      start_idx: int, pipeline: str, git_hash: str) -> list[CodeChunk]:
        chunks: list[CodeChunk] = []
        class_name = self._child_text(node, "identifier", src)
        raw_class = src[node.start_byte:node.end_byte].decode("utf-8")

        chunks.append(CodeChunk(
            chunk_id=hashlib.sha256(f"{source_file}:{start_idx}:cls".encode()).hexdigest(),
            source_file=source_file,
            chunk_type="class",
            chunk_index=start_idx,
            raw_code=raw_class,
            class_name=class_name,
            docstring=self._docstring(node, src),
            line_start=node.start_point[0] + 1,
            line_end=node.end_point[0] + 1,
            pipeline_name=pipeline,
            git_commit_hash=git_hash,
        ))

        body = next((c for c in node.children if c.type == "block"), None)
        if body:
            for i, child in enumerate(body.children):
                if child.type == "function_definition":
                    m = self._fn_chunk(child, src, source_file, start_idx + i + 1, pipeline, git_hash)
                    m.class_name = class_name
                    m.chunk_type = "method"
                    chunks.append(m)
        return chunks

    def _module_chunk(self, source: str, source_file: str, pipeline: str, git_hash: str) -> CodeChunk:
        return CodeChunk(
            chunk_id=hashlib.sha256(source_file.encode()).hexdigest(),
            source_file=source_file,
            chunk_type="module",
            chunk_index=0,
            raw_code=source,
            pipeline_name=pipeline,
            line_start=1,
            line_end=source.count("\n") + 1,
            git_commit_hash=git_hash,
        )

    # ── helpers ──────────────────────────────────────────────────────────────

    def _child_text(self, node: "Node", child_type: str, src: bytes) -> str:
        for child in node.children:
            if child.type == child_type:
                return src[child.start_byte:child.end_byte].decode("utf-8")
        return ""

    def _docstring(self, node: "Node", src: bytes) -> Optional[str]:
        body = next((c for c in node.children if c.type == "block"), None)
        if not body:
            return None
        for child in body.children:
            if child.type == "expression_statement":
                for sub in child.children:
                    if sub.type == "string":
                        raw = src[sub.start_byte:sub.end_byte].decode("utf-8")
                        return raw.strip('"""\'').strip()
        return None

    def _decorators(self, node: "Node", src: bytes) -> list[str]:
        return [
            src[c.start_byte:c.end_byte].decode("utf-8")
            for c in node.children if c.type == "decorator"
        ]

    def _return_type(self, node: "Node", src: bytes) -> Optional[str]:
        for child in node.children:
            if child.type == "type":
                return src[child.start_byte:child.end_byte].decode("utf-8")
        return None

    # ── regex fallback ────────────────────────────────────────────────────────

    def _regex_fallback(
        self, source: str, source_file: str, pipeline: str, git_hash: str
    ) -> list[CodeChunk]:
        pattern = re.compile(r"^(def |class )", re.MULTILINE)
        lines = source.splitlines(keepends=True)
        boundaries = [m.start() for m in pattern.finditer(source)] + [len(source)]

        chunks: list[CodeChunk] = []
        for i, (start, end) in enumerate(zip(boundaries, boundaries[1:])):
            raw = source[start:end].strip()
            if not raw:
                continue
            first_line = raw.split("\n")[0]
            ctype = "function" if first_line.lstrip().startswith("def ") else "class"
            chunks.append(CodeChunk(
                chunk_id=hashlib.sha256(f"{source_file}:{i}".encode()).hexdigest(),
                source_file=source_file,
                chunk_type=ctype,
                chunk_index=i,
                raw_code=raw,
                function_name=re.search(r"(?:def|class)\s+(\w+)", first_line, re.I) and
                              re.search(r"(?:def|class)\s+(\w+)", first_line).group(1),
                pipeline_name=pipeline,
                git_commit_hash=git_hash,
            ))

        return chunks or [self._module_chunk(source, source_file, pipeline, git_hash)]
PYEOF

cat << 'PYEOF' > ingestion/chunkers/sql_chunker.py
"""
SQL statement-level chunker.
Splits SQL files at semicolons, classifies each statement (DDL/DML/CTE),
and extracts referenced table names.
"""
from __future__ import annotations

import hashlib
import logging
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

DDL_PATTERN = re.compile(r"^\s*(CREATE|DROP|ALTER|TRUNCATE)\s+", re.I)
DML_PATTERN = re.compile(r"^\s*(INSERT|UPDATE|DELETE|MERGE)\s+", re.I)
SELECT_PATTERN = re.compile(r"^\s*(SELECT|WITH)\s+", re.I)
TABLE_REF_PATTERN = re.compile(
    r"(?:FROM|JOIN|INTO|UPDATE|MERGE\s+INTO|TABLE)\s+([`\"\[]?\w+[`\"\]]?)",
    re.I,
)


def _classify(stmt: str) -> str:
    if DDL_PATTERN.match(stmt):
        return "DDL"
    if DML_PATTERN.match(stmt):
        return "DML"
    if SELECT_PATTERN.match(stmt):
        return "SELECT"
    return "OTHER"


def _extract_tables(stmt: str) -> list[str]:
    return list({m.group(1).strip('`"[]') for m in TABLE_REF_PATTERN.finditer(stmt)})


@dataclass
class SQLChunk:
    chunk_id: str
    source_file: str
    chunk_type: str = "sql"
    chunk_index: int = 0
    language: str = "sql"
    raw_code: str = ""
    summary: str = ""
    operation_type: str = ""   # DDL | DML | SELECT | OTHER
    tables_referenced: list[str] = field(default_factory=list)
    cte_names: list[str] = field(default_factory=list)
    pipeline_name: str = ""
    pii_flag: bool = False
    tags: list[str] = field(default_factory=list)
    git_commit_hash: str = ""
    content_hash: str = ""
    source_type: str = "sql"

    def __post_init__(self) -> None:
        if not self.content_hash:
            self.content_hash = hashlib.sha256(self.raw_code.encode()).hexdigest()[:16]


class SQLChunker:
    """Splits a .sql file into per-statement chunks."""

    # ── CTE detection ─────────────────────────────────────────────────────────
    _CTE_RE = re.compile(r"\bWITH\s+(\w+)\s+AS\s*\(", re.I)

    def chunk(self, file_path: Path, git_commit_hash: str = "") -> list[SQLChunk]:
        source = file_path.read_text(encoding="utf-8")
        pipeline_name = file_path.stem
        statements = self._split_statements(source)

        chunks: list[SQLChunk] = []
        for idx, stmt in enumerate(statements):
            if not stmt.strip():
                continue
            op_type = _classify(stmt)
            cte_names = [m.group(1) for m in self._CTE_RE.finditer(stmt)]
            chunks.append(SQLChunk(
                chunk_id=hashlib.sha256(f"{file_path}:{idx}".encode()).hexdigest(),
                source_file=str(file_path),
                chunk_index=idx,
                raw_code=stmt.strip(),
                operation_type=op_type,
                tables_referenced=_extract_tables(stmt),
                cte_names=cte_names,
                pipeline_name=pipeline_name,
                git_commit_hash=git_commit_hash,
            ))

        logger.debug("SQL chunker: %s → %d statements", file_path.name, len(chunks))
        return chunks

    def _split_statements(self, source: str) -> list[str]:
        """Split on semicolons, respecting single-line comments."""
        # Strip block comments first
        source = re.sub(r"/\*.*?\*/", " ", source, flags=re.DOTALL)
        parts: list[str] = []
        current: list[str] = []
        for line in source.splitlines():
            stripped = line.strip()
            if stripped.startswith("--"):
                current.append(line)
                continue
            if ";" in line:
                # Split line at semicolon
                before, _, after = line.partition(";")
                current.append(before)
                parts.append("\n".join(current))
                current = [after] if after.strip() else []
            else:
                current.append(line)
        if current and "".join(current).strip():
            parts.append("\n".join(current))
        return parts
PYEOF

cat << 'PYEOF' > ingestion/chunkers/yaml_chunker.py
"""
YAML pipeline/DAG chunker.
Parses Airflow-style DAG YAML files and extracts per-task and top-level
configuration blocks as independent chunks.
"""
from __future__ import annotations

import hashlib
import logging
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

import yaml

logger = logging.getLogger(__name__)


@dataclass
class YAMLChunk:
    chunk_id: str
    source_file: str
    chunk_type: str = "yaml"
    chunk_index: int = 0
    language: str = "yaml"
    raw_code: str = ""
    summary: str = ""
    pipeline_name: str = ""
    block_type: str = ""       # "dag_config" | "task" | "slo"
    operator_type: Optional[str] = None
    task_id: Optional[str] = None
    pii_flag: bool = False
    tags: list[str] = field(default_factory=list)
    git_commit_hash: str = ""
    content_hash: str = ""
    source_type: str = "yaml"

    def __post_init__(self) -> None:
        if not self.content_hash:
            self.content_hash = hashlib.sha256(self.raw_code.encode()).hexdigest()[:16]


class YAMLChunker:
    """Extracts pipeline config blocks from Airflow YAML DAG definitions."""

    def chunk(self, file_path: Path, git_commit_hash: str = "") -> list[YAMLChunk]:
        raw_text = file_path.read_text(encoding="utf-8")
        try:
            doc: dict[str, Any] = yaml.safe_load(raw_text)
        except yaml.YAMLError as e:
            logger.warning("YAML parse error in %s: %s", file_path, e)
            return []

        pipeline_name = doc.get("dag_id", file_path.stem)
        chunks: list[YAMLChunk] = []
        idx = 0

        # Chunk 0: top-level DAG configuration (everything except tasks)
        dag_config = {k: v for k, v in doc.items() if k != "tasks"}
        chunks.append(YAMLChunk(
            chunk_id=hashlib.sha256(f"{file_path}:dag_config".encode()).hexdigest(),
            source_file=str(file_path),
            chunk_index=idx,
            raw_code=yaml.dump(dag_config, default_flow_style=False),
            pipeline_name=pipeline_name,
            block_type="dag_config",
        ))
        idx += 1

        # Per-task chunks
        for task in doc.get("tasks", []):
            task_id = task.get("task_id", f"task_{idx}")
            chunks.append(YAMLChunk(
                chunk_id=hashlib.sha256(f"{file_path}:{task_id}".encode()).hexdigest(),
                source_file=str(file_path),
                chunk_index=idx,
                raw_code=yaml.dump(task, default_flow_style=False),
                pipeline_name=pipeline_name,
                block_type="task",
                operator_type=task.get("operator"),
                task_id=task_id,
                git_commit_hash=git_commit_hash,
            ))
            idx += 1

        # SLO block if present
        if "slo" in doc:
            chunks.append(YAMLChunk(
                chunk_id=hashlib.sha256(f"{file_path}:slo".encode()).hexdigest(),
                source_file=str(file_path),
                chunk_index=idx,
                raw_code=yaml.dump({"slo": doc["slo"]}, default_flow_style=False),
                pipeline_name=pipeline_name,
                block_type="slo",
                git_commit_hash=git_commit_hash,
            ))

        logger.debug("YAML chunker: %s → %d chunks", file_path.name, len(chunks))
        return chunks
PYEOF

cat << 'PYEOF' > ingestion/chunkers/semantic_chunker.py
"""
Semantic Markdown/text chunker.
Splits at heading boundaries with a 512-token sliding window for oversized sections.
Also handles dbt manifest.json node extraction.
"""
from __future__ import annotations

import hashlib
import json
import logging
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

logger = logging.getLogger(__name__)

HEADING_RE = re.compile(r"^(#{1,6})\s+(.+)$", re.MULTILINE)
APPROX_CHARS_PER_TOKEN = 4
MAX_CHUNK_TOKENS = 512


@dataclass
class SemanticChunk:
    chunk_id: str
    source_file: str
    chunk_type: str = "markdown"
    chunk_index: int = 0
    language: str = "markdown"
    raw_code: str = ""
    summary: str = ""
    heading_level: int = 0
    section_title: str = ""
    pipeline_name: str = ""
    pii_flag: bool = False
    tags: list[str] = field(default_factory=list)
    git_commit_hash: str = ""
    content_hash: str = ""
    source_type: str = "markdown"

    def __post_init__(self) -> None:
        if not self.content_hash:
            self.content_hash = hashlib.sha256(self.raw_code.encode()).hexdigest()[:16]


class SemanticChunker:
    """Chunks Markdown at heading boundaries, with sliding window for long sections."""

    def chunk(self, file_path: Path, git_commit_hash: str = "") -> list[SemanticChunk]:
        source = file_path.read_text(encoding="utf-8")
        pipeline_name = file_path.stem

        if file_path.suffix == ".json":
            return self._chunk_json(file_path, source, pipeline_name, git_commit_hash)

        return self._chunk_markdown(source, str(file_path), pipeline_name, git_commit_hash)

    def _chunk_markdown(
        self, source: str, source_file: str, pipeline_name: str, git_hash: str
    ) -> list[SemanticChunk]:
        matches = list(HEADING_RE.finditer(source))
        if not matches:
            return [SemanticChunk(
                chunk_id=hashlib.sha256(source_file.encode()).hexdigest(),
                source_file=source_file,
                chunk_index=0,
                raw_code=source[:MAX_CHUNK_TOKENS * APPROX_CHARS_PER_TOKEN],
                pipeline_name=pipeline_name,
                git_commit_hash=git_hash,
            )]

        boundaries = [m.start() for m in matches] + [len(source)]
        chunks: list[SemanticChunk] = []
        for i, (match, start, end) in enumerate(
            zip(matches, boundaries, boundaries[1:])
        ):
            section_text = source[start:end].strip()
            level = len(match.group(1))
            title = match.group(2).strip()
            # sliding window for oversized sections
            sub_chunks = self._sliding_window(section_text)
            for j, window in enumerate(sub_chunks):
                chunks.append(SemanticChunk(
                    chunk_id=hashlib.sha256(f"{source_file}:{i}:{j}".encode()).hexdigest(),
                    source_file=source_file,
                    chunk_index=len(chunks),
                    raw_code=window,
                    heading_level=level,
                    section_title=title,
                    pipeline_name=pipeline_name,
                    git_commit_hash=git_hash,
                ))
        logger.debug("Markdown chunker: %s → %d chunks", Path(source_file).name, len(chunks))
        return chunks

    def _sliding_window(self, text: str) -> list[str]:
        max_chars = MAX_CHUNK_TOKENS * APPROX_CHARS_PER_TOKEN
        if len(text) <= max_chars:
            return [text]
        windows: list[str] = []
        start = 0
        step = int(max_chars * 0.75)
        while start < len(text):
            windows.append(text[start:start + max_chars])
            start += step
        return windows

    def _chunk_json(
        self, file_path: Path, source: str, pipeline_name: str, git_hash: str
    ) -> list[SemanticChunk]:
        """Extract dbt manifest.json model nodes as individual chunks."""
        try:
            doc = json.loads(source)
        except json.JSONDecodeError:
            return []

        chunks: list[SemanticChunk] = []
        for i, (node_id, node) in enumerate(doc.get("nodes", {}).items()):
            text = (
                f"Model: {node.get('name', '')}\n"
                f"Description: {node.get('description', '')}\n"
                f"Materialization: {node.get('config', {}).get('materialized', '')}\n"
                f"Tags: {', '.join(node.get('tags', []))}\n"
                f"Depends on: {', '.join(node.get('depends_on', {}).get('nodes', []))}\n"
                f"Columns: {json.dumps(node.get('columns', {}), indent=2)}"
            )
            chunks.append(SemanticChunk(
                chunk_id=hashlib.sha256(f"{file_path}:{node_id}".encode()).hexdigest(),
                source_file=str(file_path),
                chunk_type="dbt_model",
                chunk_index=i,
                raw_code=text,
                section_title=node.get("name", node_id),
                pipeline_name=node.get("name", pipeline_name),
                tags=node.get("tags", []),
                git_commit_hash=git_hash,
                source_type="dbt",
            ))
        logger.debug("dbt manifest chunker: %s → %d model nodes", file_path.name, len(chunks))
        return chunks
PYEOF

# ── summary_generator.py ──────────────────────────────────────────────────────
cat << 'PYEOF' > ingestion/summary_generator.py
"""
LLM-powered chunk summary generator.
Uses Groq llama3-8b-8192 (fast/cheap) to generate natural language summaries
for each code/config chunk.  These summaries are embedded for retrieval
(embed-summary/retrieve-full pattern).
"""
from __future__ import annotations

import logging
import time
from typing import Union

from groq import Groq, RateLimitError, APIError
from tenacity import retry, stop_after_attempt, wait_exponential, retry_if_exception_type

from config import settings
from ingestion.chunkers.ast_chunker import CodeChunk
from ingestion.chunkers.sql_chunker import SQLChunk
from ingestion.chunkers.yaml_chunker import YAMLChunk
from ingestion.chunkers.semantic_chunker import SemanticChunk

logger = logging.getLogger(__name__)

AnyChunk = Union[CodeChunk, SQLChunk, YAMLChunk, SemanticChunk]

SUMMARY_PROMPTS: dict[str, str] = {
    "function": (
        "Summarise this Python function for a data engineering assistant. "
        "Include: what it does, its parameters, return value, side effects, and "
        "any pipeline or ETL patterns it implements. Under 120 words."
    ),
    "method": (
        "Summarise this Python class method. Include the class context if visible, "
        "what the method does, its parameters, return value. Under 100 words."
    ),
    "class": (
        "Summarise this Python class for a data engineering context. "
        "Include: class purpose, main methods, ETL or pipeline role. Under 120 words."
    ),
    "module": (
        "Summarise this Python module. Include: overall purpose, key classes/functions, "
        "data pipeline role. Under 150 words."
    ),
    "sql": (
        "Summarise this SQL statement for a data engineering assistant. "
        "Include: operation type (DDL/DML/SELECT), tables involved, purpose, "
        "any joins or aggregations. Under 100 words."
    ),
    "yaml": (
        "Summarise this Airflow DAG or task configuration block. "
        "Include: DAG/task ID, schedule, operator type, dependencies. Under 80 words."
    ),
    "markdown": (
        "Summarise this documentation section. Include the main topic and key points. Under 80 words."
    ),
    "dbt_model": (
        "Summarise this dbt model. Include: model name, description, materialization strategy, "
        "upstream dependencies, and downstream consumers. Under 100 words."
    ),
}

_FALLBACK_PREFIX = "[AUTO-SUMMARY] "


class SummaryGenerator:
    """
    Generates natural-language summaries via Groq for the embed-summary pattern.
    Includes retry logic, rate-limit awareness, and graceful degradation.
    """

    def __init__(self, skip_llm: bool = False) -> None:
        self.skip_llm = skip_llm
        self._client: Groq | None = None
        if not skip_llm:
            self._client = Groq(api_key=settings.groq_api_key)

    @property
    def client(self) -> Groq:
        if self._client is None:
            raise RuntimeError("Groq client not initialised (skip_llm=True)")
        return self._client

    def generate(self, chunk: AnyChunk) -> str:
        """Generate a summary for a single chunk.  Returns empty string on failure."""
        if self.skip_llm:
            return self._fallback_summary(chunk)
        try:
            return self._call_llm(chunk)
        except Exception as exc:
            logger.warning("Summary generation failed for %s: %s — using fallback", chunk.chunk_id, exc)
            return self._fallback_summary(chunk)

    @retry(
        retry=retry_if_exception_type((RateLimitError, APIError)),
        stop=stop_after_attempt(4),
        wait=wait_exponential(multiplier=1, min=2, max=30),
        reraise=True,
    )
    def _call_llm(self, chunk: AnyChunk) -> str:
        ctype = getattr(chunk, "chunk_type", "module")
        prompt_instruction = SUMMARY_PROMPTS.get(ctype, SUMMARY_PROMPTS["module"])
        raw_code = chunk.raw_code[:3000]  # cap to avoid token overflow

        response = self.client.chat.completions.create(
            model=settings.groq_model_fast,
            messages=[
                {
                    "role": "system",
                    "content": (
                        "You are a senior data engineering assistant. "
                        "Write concise, accurate technical summaries. "
                        "Do not include preamble or meta-commentary."
                    ),
                },
                {
                    "role": "user",
                    "content": f"{prompt_instruction}\n\n```\n{raw_code}\n```",
                },
            ],
            max_tokens=200,
            temperature=0.1,
        )
        summary = response.choices[0].message.content.strip()
        time.sleep(0.3)  # polite rate-limit buffer
        return summary

    def _fallback_summary(self, chunk: AnyChunk) -> str:
        """Deterministic summary from code metadata when LLM is unavailable."""
        name = (
            getattr(chunk, "function_name", None)
            or getattr(chunk, "class_name", None)
            or getattr(chunk, "task_id", None)
            or getattr(chunk, "section_title", None)
            or chunk.source_file.split("/")[-1]
        )
        ctype = getattr(chunk, "chunk_type", "code")
        docstring = getattr(chunk, "docstring", None) or ""
        snippet = chunk.raw_code[:200].replace("\n", " ")
        return f"{_FALLBACK_PREFIX}{ctype} '{name}': {docstring or snippet}"

    def batch_generate(self, chunks: list[AnyChunk], batch_size: int = 10) -> list[AnyChunk]:
        """Generate summaries for a list of chunks in batches, mutating each chunk."""
        total = len(chunks)
        for i, chunk in enumerate(chunks):
            chunk.summary = self.generate(chunk)
            if (i + 1) % batch_size == 0:
                logger.info("Summarised %d / %d chunks", i + 1, total)
        logger.info("Summary generation complete: %d chunks", total)
        return chunks
PYEOF

# ── embedders.py ──────────────────────────────────────────────────────────────
cat << 'PYEOF' > ingestion/embedders.py
"""
Dual embedding strategy:
  - all-mpnet-base-v2  → documents, YAML, Markdown, dbt nodes  (768-dim)
  - CodeBERT (via ST)  → Python / SQL code chunks               (768-dim)
Both produce 768-dimensional embeddings for a unified ChromaDB collection.
"""
from __future__ import annotations

import logging
from functools import lru_cache
from pathlib import Path
from typing import Union

import numpy as np
from sentence_transformers import SentenceTransformer, models

from config import settings

logger = logging.getLogger(__name__)

CODE_SOURCE_TYPES = {"python", "sql"}
TEXT_MODEL_NAME = "sentence-transformers/all-mpnet-base-v2"
CODE_MODEL_BASE = "microsoft/codebert-base"
EMBED_DIM = 768


@lru_cache(maxsize=1)
def _get_text_embedder() -> SentenceTransformer:
    logger.info("Loading text embedder: %s", TEXT_MODEL_NAME)
    return SentenceTransformer(
        TEXT_MODEL_NAME,
        cache_folder=str(settings.embed_cache_dir),
    )


@lru_cache(maxsize=1)
def _get_code_embedder() -> SentenceTransformer:
    """Build CodeBERT as a SentenceTransformer with mean pooling."""
    logger.info("Loading code embedder: %s", CODE_MODEL_BASE)
    cache = str(settings.embed_cache_dir)
    word_model = models.Transformer(CODE_MODEL_BASE, cache_dir=cache)
    pool_model = models.Pooling(
        word_model.get_word_embedding_dimension(),
        pooling_mode_mean_tokens=True,
    )
    return SentenceTransformer(modules=[word_model, pool_model])


class ChunkEmbedder:
    """
    Routes chunks to the appropriate embedding model based on source_type,
    then returns normalised 768-dim float vectors.
    """

    def embed_chunk(self, summary: str, source_type: str = "python") -> list[float]:
        """Embed a single chunk summary.  source_type routes model selection."""
        embedder = _get_code_embedder() if source_type in CODE_SOURCE_TYPES else _get_text_embedder()
        vector: np.ndarray = embedder.encode(summary, normalize_embeddings=True, show_progress_bar=False)
        return vector.tolist()

    def embed_batch(
        self, summaries: list[str], source_types: list[str], batch_size: int = 64
    ) -> list[list[float]]:
        """
        Embed a batch of summaries.  Groups by model to minimise model-switching overhead.
        Returns a list of vectors in the same order as input.
        """
        if not summaries:
            return []

        code_idx = [i for i, st in enumerate(source_types) if st in CODE_SOURCE_TYPES]
        text_idx = [i for i, st in enumerate(source_types) if st not in CODE_SOURCE_TYPES]

        result: list[list[float]] = [[]] * len(summaries)

        if code_idx:
            code_summaries = [summaries[i] for i in code_idx]
            code_vecs = _get_code_embedder().encode(
                code_summaries, normalize_embeddings=True,
                batch_size=batch_size, show_progress_bar=True
            )
            for i, vec in zip(code_idx, code_vecs):
                result[i] = vec.tolist()

        if text_idx:
            text_summaries = [summaries[i] for i in text_idx]
            text_vecs = _get_text_embedder().encode(
                text_summaries, normalize_embeddings=True,
                batch_size=batch_size, show_progress_bar=True
            )
            for i, vec in zip(text_idx, text_vecs):
                result[i] = vec.tolist()

        return result

    def embed_query(self, query: str) -> list[float]:
        """Embed a user query using the text embedder (queries are natural language)."""
        vec: np.ndarray = _get_text_embedder().encode(
            query, normalize_embeddings=True, show_progress_bar=False
        )
        return vec.tolist()
PYEOF

# ── metadata_enricher.py ──────────────────────────────────────────────────────
cat << 'PYEOF' > ingestion/metadata_enricher.py
"""
Metadata enricher: attaches PII flags, pipeline tags, and git commit hash
to each chunk before it is written to ChromaDB.
"""
from __future__ import annotations

import json
import logging
import subprocess
from pathlib import Path
from typing import Union

from ingestion.chunkers.ast_chunker import CodeChunk
from ingestion.chunkers.sql_chunker import SQLChunk
from ingestion.chunkers.yaml_chunker import YAMLChunk
from ingestion.chunkers.semantic_chunker import SemanticChunk

logger = logging.getLogger(__name__)

AnyChunk = Union[CodeChunk, SQLChunk, YAMLChunk, SemanticChunk]

# Load PII registry at module import (cheap, ~6 rows)
_PII_REGISTRY: dict[str, set[str]] = {}

def _load_pii_registry(pii_json_path: Path | None = None) -> None:
    global _PII_REGISTRY
    if pii_json_path is None:
        pii_json_path = Path(__file__).parent.parent / "data" / "catalogue" / "pii_registry.json"
    if not pii_json_path.exists():
        logger.warning("PII registry not found at %s", pii_json_path)
        return
    rows = json.loads(pii_json_path.read_text())
    for row in rows:
        table = row["table_name"]
        col = row["column_name"]
        _PII_REGISTRY.setdefault(table, set()).add(col)
    logger.info("PII registry loaded: %d tables", len(_PII_REGISTRY))


def _get_git_hash(file_path: Path) -> str:
    """Return the latest git commit hash for a file, or empty string on failure."""
    try:
        result = subprocess.run(
            ["git", "log", "-1", "--format=%H", "--", str(file_path)],
            capture_output=True, text=True, timeout=5,
            cwd=file_path.parent,
        )
        return result.stdout.strip()[:12] or ""
    except Exception:
        return ""


def _is_pii(chunk: AnyChunk) -> bool:
    """Determine if a chunk references PII-tagged columns."""
    pipeline = getattr(chunk, "pipeline_name", "").lower()
    raw = chunk.raw_code.lower()
    for table, cols in _PII_REGISTRY.items():
        if table.lower() in raw or table.lower() in pipeline:
            for col in cols:
                if col.lower() in raw:
                    return True
    return False


class MetadataEnricher:
    """Attaches git hashes, PII flags, and tags to chunks in-place."""

    def __init__(self) -> None:
        _load_pii_registry()

    def enrich(self, chunk: AnyChunk) -> AnyChunk:
        # Git hash
        if not chunk.git_commit_hash:
            chunk.git_commit_hash = _get_git_hash(Path(chunk.source_file))

        # PII flag
        chunk.pii_flag = _is_pii(chunk)

        # Tags — ensure source_type tag is present
        st = getattr(chunk, "source_type", "unknown")
        if st not in chunk.tags:
            chunk.tags.append(st)
        if chunk.pii_flag and "pii" not in chunk.tags:
            chunk.tags.append("pii")

        return chunk

    def enrich_batch(self, chunks: list[AnyChunk]) -> list[AnyChunk]:
        return [self.enrich(c) for c in chunks]
PYEOF

# ── watcher.py ────────────────────────────────────────────────────────────────
cat << 'PYEOF' > ingestion/watcher.py
"""
File-system watcher for incremental re-indexing.
Uses watchdog to detect .py, .sql, .yml, .yaml, .md file changes
and emits events to a queue consumed by IngestionPipeline.
"""
from __future__ import annotations

import logging
import queue
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from watchdog.events import FileSystemEventHandler, FileModifiedEvent, FileCreatedEvent
from watchdog.observers import Observer

logger = logging.getLogger(__name__)

WATCHED_EXTENSIONS = {".py", ".sql", ".yml", ".yaml", ".md", ".json"}


@dataclass
class FileChangeEvent:
    file_path: str
    event_type: Literal["created", "modified", "deleted"]


class _PipelineEventHandler(FileSystemEventHandler):
    def __init__(self, change_queue: queue.Queue[FileChangeEvent]) -> None:
        super().__init__()
        self._queue = change_queue

    def _handle(self, event_type: str, src_path: str) -> None:
        if Path(src_path).suffix not in WATCHED_EXTENSIONS:
            return
        self._queue.put(FileChangeEvent(file_path=src_path, event_type=event_type))  # type: ignore[arg-type]

    def on_modified(self, event: FileModifiedEvent) -> None:
        if not event.is_directory:
            self._handle("modified", event.src_path)

    def on_created(self, event: FileCreatedEvent) -> None:
        if not event.is_directory:
            self._handle("created", event.src_path)


class PipelineWatcher:
    """
    Watches a repository path for file changes and feeds them to a queue.
    Run start() in a background thread; consume the queue in the ingestion loop.
    """

    def __init__(self, watch_path: str | Path) -> None:
        self.watch_path = str(watch_path)
        self.change_queue: queue.Queue[FileChangeEvent] = queue.Queue()
        self._observer = Observer()
        self._stop_event = threading.Event()

    def start(self) -> None:
        handler = _PipelineEventHandler(self.change_queue)
        self._observer.schedule(handler, self.watch_path, recursive=True)
        self._observer.start()
        logger.info("File watcher started on %s", self.watch_path)

    def stop(self) -> None:
        self._observer.stop()
        self._observer.join()
        logger.info("File watcher stopped")

    def drain(self, timeout: float = 1.0) -> list[FileChangeEvent]:
        """Drain all available events from the queue (non-blocking)."""
        events: list[FileChangeEvent] = []
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                events.append(self.change_queue.get_nowait())
            except queue.Empty:
                break
        return events
PYEOF

# ── ingest_pipeline.py ────────────────────────────────────────────────────────
cat << 'PYEOF' > ingestion/ingest_pipeline.py
"""
Ingestion orchestrator — Phase 1 entry point.
Discovers files, routes to chunkers, generates summaries, embeds, and
writes to ChromaDB + BM25 index.  Supports incremental updates via SHA-256
file hash comparison.
"""
from __future__ import annotations

import hashlib
import json
import logging
import pickle
from pathlib import Path
from typing import Union

import chromadb
from rank_bm25 import BM25Okapi

from config import settings
from ingestion.chunkers.ast_chunker import ASTChunker, CodeChunk
from ingestion.chunkers.sql_chunker import SQLChunker, SQLChunk
from ingestion.chunkers.yaml_chunker import YAMLChunker, YAMLChunk
from ingestion.chunkers.semantic_chunker import SemanticChunker, SemanticChunk
from ingestion.embedders import ChunkEmbedder
from ingestion.metadata_enricher import MetadataEnricher
from ingestion.summary_generator import SummaryGenerator

logging.basicConfig(level=settings.log_level, format="%(asctime)s [%(levelname)s] %(name)s — %(message)s")
logger = logging.getLogger(__name__)

AnyChunk = Union[CodeChunk, SQLChunk, YAMLChunk, SemanticChunk]

EXTENSION_MAP = {
    ".py":   "python",
    ".sql":  "sql",
    ".yml":  "yaml",
    ".yaml": "yaml",
    ".md":   "markdown",
    ".json": "json",
}

HASH_STORE_PATH = Path("./data/.file_hashes.json")


def _file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class ChromaWriter:
    """Writes enriched chunks with embeddings to a persistent ChromaDB collection."""

    COLLECTION_NAME = "pipelinemind"

    def __init__(self) -> None:
        settings.chroma_path.mkdir(parents=True, exist_ok=True)
        client = chromadb.PersistentClient(path=str(settings.chroma_path))
        self.collection = client.get_or_create_collection(
            self.COLLECTION_NAME,
            metadata={"hnsw:space": "cosine"},
        )
        logger.info("ChromaDB collection '%s' ready", self.COLLECTION_NAME)

    def upsert(self, chunks: list[AnyChunk], embeddings: list[list[float]]) -> int:
        if not chunks:
            return 0
        ids, docs, metas, embeds = [], [], [], []
        for chunk, vec in zip(chunks, embeddings):
            ids.append(chunk.chunk_id)
            docs.append(chunk.summary or chunk.raw_code[:500])
            metas.append({
                "source_file":       chunk.source_file,
                "chunk_type":        getattr(chunk, "chunk_type", "unknown"),
                "chunk_index":       chunk.chunk_index,
                "pipeline_name":     chunk.pipeline_name,
                "source_type":       getattr(chunk, "source_type", "unknown"),
                "language":          getattr(chunk, "language", ""),
                "pii_flag":          str(chunk.pii_flag),
                "tags":              ",".join(chunk.tags),
                "content_hash":      chunk.content_hash,
                "git_commit_hash":   chunk.git_commit_hash,
                "function_name":     getattr(chunk, "function_name", "") or "",
                "class_name":        getattr(chunk, "class_name", "") or "",
                "line_start":        str(getattr(chunk, "line_start", 0)),
                "line_end":          str(getattr(chunk, "line_end", 0)),
                "raw_implementation": chunk.raw_code,  # retrieve-full pattern
            })
            embeds.append(vec)

        self.collection.upsert(ids=ids, documents=docs, metadatas=metas, embeddings=embeds)
        return len(ids)


class BM25Writer:
    """Maintains a BM25 index over chunk summaries for sparse retrieval."""

    def __init__(self) -> None:
        self._corpus: list[str] = []
        self._chunk_ids: list[str] = []
        self._index: BM25Okapi | None = None

    def add(self, chunks: list[AnyChunk]) -> None:
        for chunk in chunks:
            doc = chunk.summary or chunk.raw_code[:500]
            self._corpus.append(doc)
            self._chunk_ids.append(chunk.chunk_id)
        self._index = BM25Okapi([d.lower().split() for d in self._corpus])

    def save(self) -> None:
        payload = {"corpus": self._corpus, "chunk_ids": self._chunk_ids}
        with open(settings.bm25_index_path, "wb") as fh:
            pickle.dump(payload, fh)
        logger.info("BM25 index saved: %d documents → %s", len(self._corpus), settings.bm25_index_path)


class IngestionPipeline:
    """
    Full ingestion orchestrator:
      discover → chunk → enrich → summarise → embed → ChromaDB + BM25
    """

    def __init__(self, skip_summaries: bool = False, force_reindex: bool = False) -> None:
        self.skip_summaries = skip_summaries
        self.force_reindex = force_reindex
        self.chunkers = {
            "python":   ASTChunker(),
            "sql":      SQLChunker(),
            "yaml":     YAMLChunker(),
            "markdown": SemanticChunker(),
            "json":     SemanticChunker(),
        }
        self.enricher  = MetadataEnricher()
        self.summariser = SummaryGenerator(skip_llm=skip_summaries)
        self.embedder  = ChunkEmbedder()
        self.chroma    = ChromaWriter()
        self.bm25      = BM25Writer()
        self._hashes: dict[str, str] = self._load_hashes()

    # ── hash cache ────────────────────────────────────────────────────────────

    def _load_hashes(self) -> dict[str, str]:
        if HASH_STORE_PATH.exists():
            return json.loads(HASH_STORE_PATH.read_text())
        return {}

    def _save_hashes(self) -> None:
        HASH_STORE_PATH.parent.mkdir(parents=True, exist_ok=True)
        HASH_STORE_PATH.write_text(json.dumps(self._hashes, indent=2))

    def _needs_indexing(self, path: Path) -> bool:
        if self.force_reindex:
            return True
        current = _file_sha256(path)
        if self._hashes.get(str(path)) == current:
            return False
        self._hashes[str(path)] = current
        return True

    # ── discovery ─────────────────────────────────────────────────────────────

    def _discover(self, *search_paths: str | Path) -> list[Path]:
        found: list[Path] = []
        for sp in search_paths:
            p = Path(sp)
            if p.is_file():
                found.append(p)
            elif p.is_dir():
                for ext in EXTENSION_MAP:
                    found.extend(p.rglob(f"*{ext}"))
        return [f for f in found if self._needs_indexing(f)]

    # ── run ───────────────────────────────────────────────────────────────────

    def run(
        self,
        repo_path: str | Path = "./data/pipeline_repo",
        sql_path: str | Path = "./data/sql",
        yaml_path: str | Path = "./data/dags",
        dbt_path: str | Path = "./data/dbt_project",
    ) -> dict:
        logger.info("=== PipelineMind Ingestion Started ===")
        all_files = self._discover(repo_path, sql_path, yaml_path, dbt_path)
        if not all_files:
            logger.info("No new/changed files detected — skipping ingestion")
            return {"files": 0, "chunks": 0}

        logger.info("Processing %d file(s)", len(all_files))
        all_chunks: list[AnyChunk] = []

        for file_path in all_files:
            ext = file_path.suffix.lower()
            lang = EXTENSION_MAP.get(ext, "markdown")
            chunker = self.chunkers.get(lang, self.chunkers["markdown"])
            try:
                chunks = chunker.chunk(file_path)
                chunks = self.enricher.enrich_batch(chunks)
                all_chunks.extend(chunks)
                logger.info("  %s → %d chunks", file_path.name, len(chunks))
            except Exception as exc:
                logger.error("  FAILED to chunk %s: %s", file_path, exc)

        if not all_chunks:
            logger.warning("No chunks produced — check file paths")
            return {"files": len(all_files), "chunks": 0}

        # Summarise
        logger.info("Generating summaries for %d chunks (skip_llm=%s)", len(all_chunks), self.skip_summaries)
        all_chunks = self.summariser.batch_generate(all_chunks)

        # Embed
        logger.info("Embedding %d chunks ...", len(all_chunks))
        summaries    = [c.summary or c.raw_code[:300] for c in all_chunks]
        source_types = [getattr(c, "source_type", "python") for c in all_chunks]
        embeddings   = self.embedder.embed_batch(summaries, source_types)

        # Write
        n_chroma = self.chroma.upsert(all_chunks, embeddings)
        self.bm25.add(all_chunks)
        self.bm25.save()
        self._save_hashes()

        result = {"files": len(all_files), "chunks": n_chroma}
        logger.info("=== Ingestion Complete: %d chunks across %d files ===", n_chroma, len(all_files))
        return result


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="PipelineMind ingestion pipeline")
    parser.add_argument("--repo-path",  default="./data/pipeline_repo")
    parser.add_argument("--sql-path",   default="./data/sql")
    parser.add_argument("--yaml-path",  default="./data/dags")
    parser.add_argument("--dbt-path",   default="./data/dbt_project")
    parser.add_argument("--skip-summaries", action="store_true",
                        help="Skip Groq LLM calls — use fallback summaries (faster, lower quality)")
    parser.add_argument("--force-reindex", action="store_true",
                        help="Re-index all files regardless of hash cache")
    args = parser.parse_args()

    pipeline = IngestionPipeline(
        skip_summaries=args.skip_summaries,
        force_reindex=args.force_reindex,
    )
    pipeline.run(
        repo_path=args.repo_path,
        sql_path=args.sql_path,
        yaml_path=args.yaml_path,
        dbt_path=args.dbt_path,
    )
PYEOF

# ==============================================================================
# SECTION: Retrieval Modules
# ==============================================================================
step "Writing retrieval modules"

cat << 'PYEOF' > retrieval/chroma_retriever.py
"""
Dense retriever: cosine similarity search over ChromaDB HNSW index.
Retrieves top-K chunks by embedding the (HyDE-processed) query.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass, field
from pathlib import Path

import chromadb

from config import settings
from ingestion.embedders import ChunkEmbedder

logger = logging.getLogger(__name__)


@dataclass
class RetrievedChunk:
    chunk_id: str
    document: str          # summary text (what was embedded)
    raw_implementation: str  # full source code from metadata
    source_file: str
    chunk_type: str
    pipeline_name: str
    source_type: str
    pii_flag: bool
    tags: list[str]
    git_commit_hash: str
    function_name: str
    class_name: str
    line_start: int
    line_end: int
    distance: float = 0.0       # cosine distance (lower = more similar)
    score: float = 0.0          # 1 - distance (higher = more similar)
    rank: int = 0
    retrieval_method: str = "dense"
    metadata: dict = field(default_factory=dict)


class ChromaRetriever:
    """Semantic retrieval from the ChromaDB HNSW index."""

    COLLECTION_NAME = "pipelinemind"

    def __init__(self) -> None:
        client = chromadb.PersistentClient(path=str(settings.chroma_path))
        self.collection = client.get_or_create_collection(
            self.COLLECTION_NAME,
            metadata={"hnsw:space": "cosine"},
        )
        self.embedder = ChunkEmbedder()
        logger.info(
            "ChromaRetriever ready — collection has %d documents",
            self.collection.count(),
        )

    def retrieve(
        self,
        query: str,
        top_k: int | None = None,
        filters: dict | None = None,
    ) -> list[RetrievedChunk]:
        """
        Embed the query and retrieve the top-K most similar chunks.

        Args:
            query:   Natural language query (or HyDE hypothetical document).
            top_k:   Number of results to return. Defaults to settings.top_k_dense.
            filters: Optional ChromaDB 'where' clause for metadata filtering.
        """
        k = top_k or settings.top_k_dense
        query_vec = self.embedder.embed_query(query)

        kwargs: dict = {"query_embeddings": [query_vec], "n_results": k}
        if filters:
            kwargs["where"] = filters

        results = self.collection.query(**kwargs)
        return self._parse(results)

    def _parse(self, results: dict) -> list[RetrievedChunk]:
        chunks: list[RetrievedChunk] = []
        ids       = results.get("ids", [[]])[0]
        docs      = results.get("documents", [[]])[0]
        metas     = results.get("metadatas", [[]])[0]
        distances = results.get("distances", [[]])[0]

        for rank, (cid, doc, meta, dist) in enumerate(zip(ids, docs, metas, distances)):
            score = max(0.0, 1.0 - dist)
            chunks.append(RetrievedChunk(
                chunk_id=cid,
                document=doc,
                raw_implementation=meta.get("raw_implementation", ""),
                source_file=meta.get("source_file", ""),
                chunk_type=meta.get("chunk_type", ""),
                pipeline_name=meta.get("pipeline_name", ""),
                source_type=meta.get("source_type", ""),
                pii_flag=meta.get("pii_flag", "false").lower() == "true",
                tags=meta.get("tags", "").split(","),
                git_commit_hash=meta.get("git_commit_hash", ""),
                function_name=meta.get("function_name", ""),
                class_name=meta.get("class_name", ""),
                line_start=int(meta.get("line_start", 0)),
                line_end=int(meta.get("line_end", 0)),
                distance=dist,
                score=score,
                rank=rank,
                retrieval_method="dense",
                metadata=meta,
            ))
        return chunks
PYEOF

cat << 'PYEOF' > retrieval/bm25_retriever.py
"""
Sparse BM25 retriever.
Loads the pickled BM25Okapi index built during ingestion and retrieves
top-K chunks by keyword relevance.  Uses the same RetrievedChunk type
for uniform fusion downstream.
"""
from __future__ import annotations

import logging
import pickle
from pathlib import Path

from rank_bm25 import BM25Okapi

from config import settings
from retrieval.chroma_retriever import RetrievedChunk

logger = logging.getLogger(__name__)


class BM25Retriever:
    """Sparse keyword retrieval using BM25Okapi."""

    def __init__(self) -> None:
        self._index: BM25Okapi | None = None
        self._corpus: list[str] = []
        self._chunk_ids: list[str] = []
        self._load()

    def _load(self) -> None:
        path = settings.bm25_index_path
        if not path.exists():
            logger.warning("BM25 index not found at %s — sparse retrieval disabled", path)
            return
        with open(path, "rb") as fh:
            payload = pickle.load(fh)
        self._corpus    = payload["corpus"]
        self._chunk_ids = payload["chunk_ids"]
        self._index     = BM25Okapi([doc.lower().split() for doc in self._corpus])
        logger.info("BM25 index loaded: %d documents", len(self._corpus))

    @property
    def available(self) -> bool:
        return self._index is not None

    def retrieve(self, query: str, top_k: int | None = None) -> list[RetrievedChunk]:
        if not self.available:
            logger.warning("BM25 index not available — returning empty results")
            return []

        k = top_k or settings.top_k_sparse
        tokens = query.lower().split()
        scores = self._index.get_scores(tokens)  # type: ignore[union-attr]

        # Rank by score descending
        ranked_idx = sorted(range(len(scores)), key=lambda i: scores[i], reverse=True)[:k]

        chunks: list[RetrievedChunk] = []
        max_score = float(scores[ranked_idx[0]]) if ranked_idx else 1.0
        for rank, idx in enumerate(ranked_idx):
            raw_score = float(scores[idx])
            norm_score = raw_score / max_score if max_score > 0 else 0.0
            chunks.append(RetrievedChunk(
                chunk_id=self._chunk_ids[idx],
                document=self._corpus[idx],
                raw_implementation="",  # BM25 does not carry metadata
                source_file="",
                chunk_type="",
                pipeline_name="",
                source_type="",
                pii_flag=False,
                tags=[],
                git_commit_hash="",
                function_name="",
                class_name="",
                line_start=0,
                line_end=0,
                distance=1.0 - norm_score,
                score=norm_score,
                rank=rank,
                retrieval_method="sparse",
            ))
        return chunks
PYEOF

cat << 'PYEOF' > retrieval/rrf_fusion.py
"""
Reciprocal Rank Fusion (RRF) for combining dense and sparse result lists.
RRF(d) = sum_over_rankers[ 1 / (k + rank(d)) ]
k=60 is the standard constant that smooths rank differences.
"""
from __future__ import annotations

import logging
from collections import defaultdict

from config import settings
from retrieval.chroma_retriever import RetrievedChunk

logger = logging.getLogger(__name__)


def reciprocal_rank_fusion(
    dense_results:  list[RetrievedChunk],
    sparse_results: list[RetrievedChunk],
    k: int | None = None,
    top_n: int | None = None,
) -> list[RetrievedChunk]:
    """
    Fuse two ranked lists using Reciprocal Rank Fusion.

    Args:
        dense_results:  Ranked list from ChromaDB dense retrieval.
        sparse_results: Ranked list from BM25 sparse retrieval.
        k:              RRF smoothing constant (default: settings.rrf_k = 60).
        top_n:          Number of results to return after fusion.

    Returns:
        Fused list sorted by RRF score descending.
    """
    rrf_k  = k    or settings.rrf_k
    top_n  = top_n or settings.top_k_fused
    rrf_scores: dict[str, float] = defaultdict(float)

    # Build a lookup of chunk_id → chunk object (prefer dense as it has more metadata)
    chunk_lookup: dict[str, RetrievedChunk] = {}

    for rank, chunk in enumerate(dense_results):
        rrf_scores[chunk.chunk_id] += 1.0 / (rrf_k + rank + 1)
        chunk_lookup[chunk.chunk_id] = chunk

    for rank, chunk in enumerate(sparse_results):
        rrf_scores[chunk.chunk_id] += 1.0 / (rrf_k + rank + 1)
        # Only store sparse chunk if not already captured from dense
        if chunk.chunk_id not in chunk_lookup:
            chunk_lookup[chunk.chunk_id] = chunk

    # Sort by fused score
    ranked_ids = sorted(rrf_scores, key=lambda cid: rrf_scores[cid], reverse=True)[:top_n]

    fused: list[RetrievedChunk] = []
    for new_rank, cid in enumerate(ranked_ids):
        chunk = chunk_lookup[cid]
        chunk.score = rrf_scores[cid]
        chunk.rank  = new_rank
        chunk.retrieval_method = "rrf"
        fused.append(chunk)

    logger.debug(
        "RRF fusion: dense=%d sparse=%d → fused=%d (k=%d)",
        len(dense_results), len(sparse_results), len(fused), rrf_k,
    )
    return fused
PYEOF

cat << 'PYEOF' > retrieval/reranker.py
"""
Cross-encoder re-ranker using ms-marco-MiniLM-L-6-v2.
Scores (query, document) pairs precisely to re-order the top-N fused results.
"""
from __future__ import annotations

import logging
from functools import lru_cache

from sentence_transformers import CrossEncoder

from config import settings
from retrieval.chroma_retriever import RetrievedChunk

logger = logging.getLogger(__name__)

MODEL_NAME = "cross-encoder/ms-marco-MiniLM-L-6-v2"


@lru_cache(maxsize=1)
def _get_cross_encoder() -> CrossEncoder:
    logger.info("Loading cross-encoder: %s", MODEL_NAME)
    return CrossEncoder(MODEL_NAME)


class Reranker:
    """Re-ranks fused results using a cross-encoder for precise relevance scoring."""

    def rerank(
        self,
        query: str,
        chunks: list[RetrievedChunk],
        top_k: int | None = None,
    ) -> list[RetrievedChunk]:
        if not chunks:
            return []
        if not settings.rerank_enabled:
            return chunks[:top_k or settings.top_k_rerank]

        k = top_k or settings.top_k_rerank
        model = _get_cross_encoder()

        # Build (query, passage) pairs — prefer summary over raw_implementation for re-ranking
        pairs = [(query, c.document[:512]) for c in chunks]
        scores = model.predict(pairs, show_progress_bar=False)

        for chunk, score in zip(chunks, scores):
            chunk.score = float(score)
            chunk.retrieval_method = "rerank"

        chunks.sort(key=lambda c: c.score, reverse=True)
        result = chunks[:k]
        for new_rank, chunk in enumerate(result):
            chunk.rank = new_rank

        logger.debug("Re-ranked %d → %d chunks (top score=%.4f)", len(chunks), len(result), result[0].score if result else 0)
        return result
PYEOF

cat << 'PYEOF' > retrieval/hyde.py
"""
Hypothetical Document Embedding (HyDE) query processor.
Generates a hypothetical answer to the query using Groq, then embeds
the hypothetical answer rather than the raw query.  This bridges the
vocabulary gap between natural language questions and technical documents.
"""
from __future__ import annotations

import logging

from groq import Groq
from tenacity import retry, stop_after_attempt, wait_exponential

from config import settings

logger = logging.getLogger(__name__)

_SYSTEM_PROMPT = (
    "You are a senior data engineering architect. "
    "Given a question about a data pipeline system, generate a realistic, technical "
    "document excerpt that would be the PERFECT answer to that question. "
    "Write it as if excerpted from actual code comments, technical documentation, "
    "or pipeline configuration. Be specific about pipeline names, table names, "
    "strategies (MERGE, SCD2, etc.) where plausible. Under 200 words."
)


class HyDEProcessor:
    """
    Generates hypothetical documents for improved recall on complex queries.
    Falls back to the original query on any Groq failure.
    """

    def __init__(self) -> None:
        self._client = Groq(api_key=settings.groq_api_key)

    @retry(stop=stop_after_attempt(3), wait=wait_exponential(min=1, max=10), reraise=False)
    def generate(self, query: str) -> str:
        """
        Returns a hypothetical document string to embed in place of the raw query.
        Falls back gracefully to the original query on failure.
        """
        if not settings.hyde_enabled:
            return query
        try:
            response = self._client.chat.completions.create(
                model=settings.groq_model_strong,
                messages=[
                    {"role": "system", "content": _SYSTEM_PROMPT},
                    {"role": "user",   "content": f"Question: {query}"},
                ],
                max_tokens=250,
                temperature=0.4,
            )
            hypo_doc = response.choices[0].message.content.strip()
            logger.debug("HyDE generated %d chars for query: '%s...'", len(hypo_doc), query[:60])
            return hypo_doc
        except Exception as exc:
            logger.warning("HyDE generation failed (%s) — using raw query", exc)
            return query
PYEOF

cat << 'PYEOF' > retrieval/context_builder.py
"""
Context builder — assembles the final LLM context from re-ranked chunks.
Responsibilities:
  1. Token budget enforcement (max_context_tokens).
  2. PII column redaction from sample values before passing to LLM.
  3. Raw code injection (embed-summary/retrieve-full pattern).
  4. Confidence score computation from top chunk's cosine similarity.
"""
from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass, field

from config import settings
from retrieval.chroma_retriever import RetrievedChunk

logger = logging.getLogger(__name__)

APPROX_CHARS_PER_TOKEN = 4
PII_REDACTION_PATTERN = re.compile(
    r"(email|phone|birth|ssn|password|secret|token)\s*[:=]\s*['\"]?[\w@.+\-]+['\"]?",
    re.I,
)


def _redact_pii(text: str) -> str:
    """Replace PII-like values with [REDACTED]."""
    return PII_REDACTION_PATTERN.sub(lambda m: m.group(0).split("=")[0].split(":")[0] + ": [REDACTED]", text)


def _estimate_tokens(text: str) -> int:
    return max(1, len(text) // APPROX_CHARS_PER_TOKEN)


@dataclass
class BuiltContext:
    chunks_used: list[RetrievedChunk]
    context_text: str
    confidence_score: float      # 0.0 – 1.0 based on top chunk similarity
    has_pii: bool
    total_tokens_estimate: int
    citations: list[dict] = field(default_factory=list)
    low_confidence: bool = False


class ContextBuilder:
    """
    Assembles a token-budgeted context string from re-ranked chunks.
    """

    def build(self, query: str, chunks: list[RetrievedChunk]) -> BuiltContext:
        if not chunks:
            return BuiltContext(
                chunks_used=[],
                context_text="No relevant documents found in the knowledge base.",
                confidence_score=0.0,
                has_pii=False,
                total_tokens_estimate=0,
                low_confidence=True,
            )

        budget = settings.max_context_tokens * APPROX_CHARS_PER_TOKEN
        selected: list[RetrievedChunk] = []
        used_chars = 0
        has_pii = False
        citations: list[dict] = []

        for chunk in chunks:
            # For code chunks, inject raw implementation; for others use summary
            if chunk.source_type in {"python", "sql"} and chunk.raw_implementation:
                body = chunk.raw_implementation
            else:
                body = chunk.document

            # PII redaction
            if chunk.pii_flag:
                body = _redact_pii(body)
                has_pii = True

            header = (
                f"[SOURCE {len(selected)+1}] "
                f"{chunk.source_file.split('/')[-1]} "
                f"({chunk.chunk_type}"
                + (f" | {chunk.function_name}" if chunk.function_name else "")
                + (f" | git:{chunk.git_commit_hash}" if chunk.git_commit_hash else "")
                + ")"
            )
            block = f"\n{header}\n```\n{body.strip()}\n```\n"

            if used_chars + len(block) > budget:
                logger.debug("Token budget reached at chunk %d", len(selected))
                break

            selected.append(chunk)
            used_chars += len(block)
            citations.append({
                "source_index": len(selected),
                "file": chunk.source_file,
                "chunk_type": chunk.chunk_type,
                "function_name": chunk.function_name,
                "git_commit_hash": chunk.git_commit_hash,
                "score": round(chunk.score, 4),
            })

        context_text = "\n".join(
            (
                f"[SOURCE {i+1}] "
                f"{c.source_file.split('/')[-1]} "
                f"({c.chunk_type}"
                + (f" | {c.function_name}" if c.function_name else "")
                + (f" | git:{c.git_commit_hash}" if c.git_commit_hash else "")
                + ")\n```\n"
                + (_redact_pii(c.raw_implementation or c.document) if c.pii_flag
                   else (c.raw_implementation if c.source_type in {"python","sql"} and c.raw_implementation
                         else c.document))
                + "\n```"
            )
            for i, c in enumerate(selected)
        )

        # Confidence from top-chunk score
        top_score = chunks[0].score if chunks else 0.0
        confidence = min(1.0, max(0.0, top_score))
        low_confidence = confidence < settings.confidence_threshold

        if low_confidence:
            logger.info("Low confidence retrieval (score=%.3f) for query: %s", confidence, query[:80])

        return BuiltContext(
            chunks_used=selected,
            context_text=context_text,
            confidence_score=confidence,
            has_pii=has_pii,
            total_tokens_estimate=_estimate_tokens(context_text),
            citations=citations,
            low_confidence=low_confidence,
        )
PYEOF

cat << 'PYEOF' > retrieval/intent_classifier.py
"""
Intent classifier: routes queries to the correct retrieval strategy.
Uses Groq llama3-70b-8192 with a structured prompt.
Falls back to CODE_QA on any failure.
"""
from __future__ import annotations

import json
import logging
from enum import Enum

from groq import Groq
from tenacity import retry, stop_after_attempt, wait_exponential

from config import settings

logger = logging.getLogger(__name__)


class Intent(str, Enum):
    CODE_QA   = "CODE_QA"    # Pipeline code understanding
    CATALOGUE = "CATALOGUE"  # Table/column/lineage queries
    HEALTH    = "HEALTH"     # Pipeline run status, SLO breaches
    ACTION    = "ACTION"     # Trigger DQ checks, impact analysis
    GENERAL   = "GENERAL"    # Generic DE education questions


_SYSTEM_PROMPT = """You are an intent classifier for a Data Engineering AI assistant.
Classify the user query into exactly one of these intents:

CODE_QA   — questions about pipeline code logic, SQL transformations, Python functions,
             configuration decisions, debugging, or implementation details.
CATALOGUE — questions about table schemas, column metadata, data lineage,
             PII classification, or data discovery.
HEALTH    — questions about pipeline run status, failures, SLO adherence,
             recent errors, or monitoring.
ACTION    — requests to trigger a DQ check, run impact analysis before a schema change,
             or execute any agentic action on the system.
GENERAL   — generic data engineering education questions with no specific pipeline context.

Respond with ONLY a JSON object: {"intent": "<INTENT>", "confidence": <0.0-1.0>}
No explanation, no markdown, no preamble."""


class IntentClassifier:
    """Classifies user queries into one of 5 retrieval intents via Groq."""

    def __init__(self) -> None:
        self._client = Groq(api_key=settings.groq_api_key)

    @retry(stop=stop_after_attempt(3), wait=wait_exponential(min=1, max=8), reraise=False)
    def classify(self, query: str) -> tuple[Intent, float]:
        """
        Returns (Intent, confidence_score).
        Falls back to CODE_QA with confidence=0.5 on any failure.
        """
        try:
            response = self._client.chat.completions.create(
                model=settings.groq_model_strong,
                messages=[
                    {"role": "system", "content": _SYSTEM_PROMPT},
                    {"role": "user",   "content": query},
                ],
                max_tokens=50,
                temperature=0.0,
            )
            raw = response.choices[0].message.content.strip()
            # Strip accidental markdown fences
            raw = raw.strip("`").strip()
            if raw.startswith("json"):
                raw = raw[4:].strip()
            parsed = json.loads(raw)
            intent_str = parsed.get("intent", "CODE_QA")
            confidence = float(parsed.get("confidence", 0.8))
            intent = Intent(intent_str)
            logger.info("Intent: %s (conf=%.2f) for '%s...'", intent, confidence, query[:60])
            return intent, confidence
        except Exception as exc:
            logger.warning("Intent classification failed (%s) — defaulting to CODE_QA", exc)
            return Intent.CODE_QA, 0.5
PYEOF

cat << 'PYEOF' > retrieval/hybrid_retriever.py
"""
Hybrid retriever orchestrator.
Combines HyDE → Dense → Sparse → RRF Fusion → Cross-encoder Re-ranking
→ Context Builder into a single retrieve() call.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass

from config import settings
from retrieval.chroma_retriever import ChromaRetriever, RetrievedChunk
from retrieval.bm25_retriever import BM25Retriever
from retrieval.rrf_fusion import reciprocal_rank_fusion
from retrieval.reranker import Reranker
from retrieval.hyde import HyDEProcessor
from retrieval.context_builder import ContextBuilder, BuiltContext
from retrieval.intent_classifier import IntentClassifier, Intent

logger = logging.getLogger(__name__)


@dataclass
class RetrievalResult:
    intent: Intent
    intent_confidence: float
    context: BuiltContext
    raw_chunks: list[RetrievedChunk]
    hyde_query: str
    original_query: str


class HybridRetriever:
    """
    Full hybrid RAG retrieval pipeline.

    Pipeline:
      1. Intent classification
      2. HyDE query expansion (if enabled)
      3. Dense retrieval (ChromaDB HNSW)
      4. Sparse retrieval (BM25)
      5. RRF fusion
      6. Cross-encoder re-ranking
      7. Context building (token budget + PII redaction + raw code injection)
    """

    def __init__(self) -> None:
        self.intent_classifier = IntentClassifier()
        self.hyde              = HyDEProcessor()
        self.dense             = ChromaRetriever()
        self.sparse            = BM25Retriever()
        self.reranker          = Reranker()
        self.context_builder   = ContextBuilder()

    def retrieve(
        self,
        query: str,
        intent_override: Intent | None = None,
        metadata_filters: dict | None = None,
    ) -> RetrievalResult:
        """
        Full retrieval pipeline.  Returns a RetrievalResult with assembled context.
        """
        # Step 1: Classify intent
        intent, intent_conf = self.intent_classifier.classify(query) if not intent_override \
            else (intent_override, 1.0)

        # For GENERAL intent — skip RAG entirely
        if intent == Intent.GENERAL:
            logger.info("GENERAL intent — skipping RAG retrieval")
            from retrieval.context_builder import BuiltContext
            empty_ctx = BuiltContext(
                chunks_used=[], context_text="", confidence_score=1.0,
                has_pii=False, total_tokens_estimate=0