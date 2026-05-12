#!/usr/bin/env bash
# ==============================================================================
# PipelineMind — Complete Documentation Generation Script
# Creates: README, SETUP, ARCHITECTURE, API_REFERENCE, DEVELOPER_GUIDE,
#          CHANGELOG, CONTRIBUTING, HANDOVER, and a bash commands cheatsheet
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[DOCS]${NC} $*"; }
step() { echo -e "\n${BLUE}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

PROJECT_DIR="/Users/as-mac-1282/Developer/genai_mini/pipelinemind"
DOCS_DIR="$PROJECT_DIR/docs"
mkdir -p "$DOCS_DIR"
cd "$PROJECT_DIR"

# ==============================================================================
# 1. README.md (root level — replaces stub)
# ==============================================================================
step "Writing README.md"
cat << 'MDEOF' > README.md
# PipelineMind

> RAG-Powered Data Engineering Assistant via MCP

PipelineMind is a production-grade, agentic AI assistant purpose-built for Data Engineers.
It combines Retrieval-Augmented Generation (RAG) over a multi-source knowledge base with
live agentic actions — giving engineers a single conversational surface to understand
codebases, explore data catalogues, monitor pipeline health, and trigger quality checks
in real time.

---

## Table of Contents

- [What It Does](#what-it-does)
- [Quick Start](#quick-start)
- [Architecture Overview](#architecture-overview)
- [MCP Tools](#mcp-tools)
- [Demo Scenarios](#demo-scenarios)
- [Project Structure](#project-structure)
- [Configuration](#configuration)
- [Running Tests](#running-tests)
- [Docker](#docker)
- [Documentation Index](#documentation-index)

---

## What It Does

| Domain | Capability |
|---|---|
| Codebase Q&A | Ask questions about pipeline logic, SQL transformations, and design decisions |
| Data Catalogue | Discover tables, trace lineage, check PII sensitivity labels |
| Pipeline Health | Inspect run status, SLO adherence, recent failures |
| Agentic Actions | Trigger DQ checks, run What-If impact analysis, search PII tables |
| Schema Drift | Proactive sidebar alerts when source table schemas change |

**Core Innovation — What-If Impact Engine:**
Before any column rename or table drop, the agent traces full lineage and surfaces every
affected downstream asset — dashboards, marts, and ML features — before code is merged.

---

## Quick Start

### Prerequisites

- Python 3.11+
- Docker Desktop (for containerised run)
- Groq API key (set in `.env`)

### 1. Clone and enter the project

```bash
cd /Users/as-mac-1282/Developer/genai_mini/pipelinemind
```

### 2. Activate the virtual environment

```bash
source .venv/bin/activate
```

### 3. Seed the database

```bash
bash scripts/seed_db.sh
```

### 4. Run ingestion — fast mode (no Groq LLM calls, uses fallback summaries)

```bash
bash scripts/ingest_fast.sh
```

### 5. Start the API backend (Terminal 1)

```bash
bash scripts/start_api.sh
```

API is live at: http://localhost:8000
Interactive docs: http://localhost:8000/docs

### 6. Start the Streamlit UI (Terminal 2)

```bash
bash scripts/start_ui.sh
```

UI is live at: http://localhost:8501

---

## Architecture Overview
┌─────────────────────────────────────────────┐
│           Streamlit UI  (port 8501)          │
│  Chat Panel | Health Dashboard | Catalogue   │
└──────────────────────┬──────────────────────┘
│ HTTP + SSE
┌──────────────────────▼──────────────────────┐
│        FastAPI Backend  (port 8000)          │
│  Intent Router | RAG Engine | Agent Loop     │
│  MCP Server (stdio) | PII Guard | Metrics    │
└──────┬──────────────────────────────┬────────┘
│                              │
┌──────▼──────┐              ┌────────▼───────┐
│  ChromaDB   │              │    DuckDB      │
│  HNSW 768d  │              │  Metadata DB   │
│  + BM25     │              │  6 tables      │
└─────────────┘              └────────────────┘
│
┌────────▼────────┐
│   Groq API      │
│  llama3-8b      │
│  llama3-70b     │
│  llama-3.3-70b  │
└─────────────────┘

Three-tier architecture: Streamlit UI → FastAPI Orchestration Backend → Data Layer + LLM.

---

## MCP Tools

| Tool | Description | Requires Approval |
|---|---|---|
| `trigger_dq_check` | Run Great Expectations DQ suite on a table | Yes |
| `get_pipeline_status` | Fetch run status and history | No |
| `get_lineage_graph` | Upstream/downstream table lineage | No |
| `analyze_lineage_impact` | What-If blast radius before schema changes | No |
| `search_pii_tables` | List all PII-tagged tables and columns | No |
| `get_slo_report` | SLO adherence report for a pipeline | No |

**MCP Primitives used:**
- Tools — 6 action tools (model-controlled)
- Resources — schema drift polling every 5 minutes (app-controlled)
- Prompts — `/diagnose_pipeline {id}` slash command (user-controlled)

---

## Demo Scenarios

**Scenario 1 — Codebase Q&A**
"Why does the orders pipeline use a MERGE strategy instead of INSERT OVERWRITE?"

**Scenario 2 — PII Discovery**
"What PII columns exist in the users table, and which pipelines write to it?"

**Scenario 3 — What-If Impact (Innovation)**
"What happens if I drop the user_id column from stg_users?"

**Scenario 4 — Health + Remediation**
"Why did the hourly ingestion fail? Run a DQ check on the upstream table."

---

## Project Structure
pipelinemind/
├── pm_config.py              # Pydantic-settings config (avoids 'config' package clash)
├── conftest.py               # pytest sys.path fix
├── pyproject.toml
├── docker-compose.yml
├── .env                      # secrets — gitignored
├── .env.example
│
├── ingestion/                # Phase 1: chunking + embedding + indexing
│   ├── chunkers/
│   │   ├── ast_chunker.py    # tree-sitter Python chunker
│   │   ├── sql_chunker.py    # SQL statement chunker
│   │   ├── yaml_chunker.py   # Airflow DAG YAML chunker
│   │   └── semantic_chunker.py # Markdown + dbt manifest chunker
│   ├── summary_generator.py  # Groq Haiku summaries (embed-summary pattern)
│   ├── embedders.py          # Dual embedder: mpnet + CodeBERT
│   ├── metadata_enricher.py  # PII flag + git hash tagging
│   ├── watcher.py            # watchdog file change detection
│   └── ingest_pipeline.py    # Orchestrator entry point
│
├── retrieval/                # Phase 2: hybrid RAG
│   ├── chroma_retriever.py   # Dense HNSW retrieval
│   ├── bm25_retriever.py     # Sparse BM25 retrieval
│   ├── rrf_fusion.py         # Reciprocal Rank Fusion
│   ├── reranker.py           # Cross-encoder ms-marco-MiniLM-L-6-v2
│   ├── hyde.py               # Hypothetical Document Embedding
│   ├── context_builder.py    # Token budget + PII redaction + raw code injection
│   ├── intent_classifier.py  # 5-intent Groq classifier
│   └── hybrid_retriever.py   # Full pipeline orchestrator
│
├── agent/                    # Phase 3: MCP + agent loop
│   ├── agent_loop.py         # Groq function-calling loop (max 5 iterations)
│   ├── mcp_server.py         # MCP server (stdio transport)
│   ├── mcp_resources.py      # Schema drift Resource polling
│   └── tools/
│       ├── validators.py     # Pydantic v2 tool input models
│       ├── dq_tools.py       # trigger_dq_check
│       ├── pipeline_tools.py # get_pipeline_status, get_slo_report
│       ├── lineage_tools.py  # get_lineage_graph, analyze_lineage_impact
│       └── catalogue_tools.py# search_pii_tables
│
├── api/                      # Phase 4: FastAPI backend
│   ├── main.py               # App entry point, middleware registration
│   ├── middleware/
│   │   ├── logging.py        # structlog JSON middleware
│   │   └── pii_guard.py      # PII response header middleware
│   ├── models/__init__.py # Pydantic request/response models
│   └── routers/
│       ├── chat.py           # POST /api/v1/chat (SSE streaming)
│       ├── pipelines.py      # Pipeline status + SLO endpoints
│       ├── catalogue.py      # Catalogue + lineage endpoints
│       ├── dq.py             # DQ trigger + results
│       └── impact.py         # What-If impact analysis
│
├── ui/                       # Phase 5: Streamlit frontend
│   ├── app.py                # Entry point
│   ├── components/
│   │   ├── chat_panel.py     # Streaming chat with citations
│   │   ├── health_dashboard.py
│   │   ├── lineage_graph.py  # streamlit-agraph DAG
│   │   ├── approval_gate.py  # Human-in-the-loop gate
│   │   └── schema_drift_banner.py
│   └── pages/
│       ├── 01_Chat.py
│       ├── 02_Health.py
│       └── 03_Catalogue.py
│
├── data/                     # Synthetic fixtures + vector/metadata stores
│   ├── pipeline_repo/        # 5 Python ETL pipelines
│   ├── sql/                  # 3 SQL schema files
│   ├── dags/                 # 3 Airflow YAML DAGs
│   ├── dbt_project/          # dbt manifest.json + catalog.json
│   ├── catalogue/            # PII registry, lineage edges, table metadata
│   ├── run_logs/             # 30-day synthetic pipeline run history
│   ├── schema_snapshots/     # Baseline for drift detection
│   ├── chroma_db/            # Persistent ChromaDB vector store
│   └── pipelinemind.db       # DuckDB metadata store
│
├── db/
│   ├── schema.sql            # DuckDB schema (6 tables)
│   └── seeder.py             # Fixture loader
│
├── tests/
│   ├── unit/                 # Chunker, RRF, validators, context builder tests
│   ├── integration/          # DuckDB tool integration tests
│   └── eval/                 # RAG evaluation harness (MRR@5, NDCG@5)
│
├── scripts/
│   ├── start_api.sh
│   ├── start_ui.sh
│   ├── ingest.sh             # Full ingestion with Groq summaries
│   ├── ingest_fast.sh        # Fast ingestion, no LLM calls
│   ├── seed_db.sh
│   └── run_tests.sh
│
└── docs/                     # This documentation directory
├── SETUP.md
├── ARCHITECTURE.md
├── API_REFERENCE.md
├── DEVELOPER_GUIDE.md
├── CHANGELOG.md
├── CONTRIBUTING.md
├── HANDOVER.md
└── BASH_COMMANDS.md

---

## Configuration

All configuration lives in `.env` (gitignored). Copy `.env.example` as a starting point.

| Variable | Default | Description |
|---|---|---|
| `GROQ_API_KEY` | required | Your Groq Cloud API key |
| `GROQ_MODEL_FAST` | `llama3-8b-8192` | Summaries and fast calls |
| `GROQ_MODEL_STRONG` | `llama3-70b-8192` | Intent classification, HyDE |
| `GROQ_MODEL_AGENT` | `llama-3.3-70b-versatile` | Agent function-calling loop |
| `CHROMA_PATH` | `./data/chroma_db` | ChromaDB persistence directory |
| `DUCKDB_PATH` | `./data/pipelinemind.db` | DuckDB file path |
| `MAX_CONTEXT_TOKENS` | `6000` | LLM context window budget |
| `CONFIDENCE_THRESHOLD` | `0.6` | Below this, model expresses uncertainty |
| `HYDE_ENABLED` | `true` | Toggle HyDE query expansion |
| `RERANK_ENABLED` | `true` | Toggle cross-encoder re-ranking |
| `AGENT_MAX_ITERATIONS` | `5` | Maximum agent loop iterations |

---

## Running Tests

```bash
# All tests
bash scripts/run_tests.sh

# Unit tests only
source .venv/bin/activate
pytest tests/unit/ -v --tb=short

# Integration tests (requires seeded DB)
pytest tests/integration/ -v --tb=short
```

---

## Docker

```bash
# Build and start all services
docker compose up --build

# Start in background
docker compose up -d

# View logs
docker compose logs -f api
docker compose logs -f ui

# Stop
docker compose down
```

Services:
- API: http://localhost:8000
- UI:  http://localhost:8501

---

## Documentation Index

| Document | Location | Purpose |
|---|---|---|
| Setup Guide | `docs/SETUP.md` | Full installation walkthrough |
| Architecture | `docs/ARCHITECTURE.md` | Deep-dive system design |
| API Reference | `docs/API_REFERENCE.md` | All 14 REST endpoints |
| Developer Guide | `docs/DEVELOPER_GUIDE.md` | Extending and contributing |
| Bash Commands | `docs/BASH_COMMANDS.md` | All commands in one place |
| Changelog | `docs/CHANGELOG.md` | Version history |
| Contributing | `docs/CONTRIBUTING.md` | Contribution guidelines |
| Handover | `docs/HANDOVER.md` | LLM-ready context handover |
MDEOF
log "README.md written"

# ==============================================================================
# 2. docs/SETUP.md
# ==============================================================================
step "Writing docs/SETUP.md"
cat << 'MDEOF' > docs/SETUP.md
# PipelineMind — Setup Guide

Complete installation and configuration guide for local development and Docker deployment.

---

## Prerequisites

| Requirement | Minimum Version | Check |
|---|---|---|
| Python | 3.11 | `python3 --version` |
| pip | 23+ | `pip --version` |
| Docker Desktop | 24+ | `docker --version` |
| Git | 2.x | `git --version` |
| Groq API Key | — | https://console.groq.com |
| Disk space | 4 GB free | For model cache + ChromaDB |
| RAM | 8 GB recommended | Sentence-transformer models |

---

## Installation — Local Development

### Step 1: Navigate to the project

```bash
cd /Users/as-mac-1282/Developer/genai_mini/pipelinemind
```

### Step 2: Create and activate the virtual environment

```bash
python3.11 -m venv .venv
source .venv/bin/activate
```

### Step 3: Install all dependencies

```bash
pip install --upgrade pip setuptools wheel

# Core runtime
pip install groq tenacity structlog pydantic pydantic-settings python-dotenv pyyaml httpx

# API layer
pip install fastapi "uvicorn[standard]" sse-starlette prometheus-client

# Data layer
pip install duckdb

# Vector search
pip install chromadb rank-bm25

# Embeddings and reranker
pip install "sentence-transformers>=3.0.0"

# Code parsing
pip install tree-sitter tree-sitter-python

# Frontend
pip install streamlit streamlit-agraph

# Utilities
pip install watchdog pandas numpy scikit-learn sqlalchemy

# Testing
pip install pytest pytest-asyncio

# Optional: DQ framework
pip install great-expectations

# Optional: MCP SDK
pip install mcp
```

### Step 4: Configure environment

```bash
cp .env.example .env
```

Edit `.env` and set your Groq API key:

```bash
GROQ_API_KEY=gsk_your_key_here
```

All other defaults work out of the box for local development.

### Step 5: Seed the DuckDB metadata store

```bash
python db/seeder.py
```

Expected output: 6 tables seeded with row counts printed to stdout.

Verify with:

```bash
python -c "
import sys; sys.path.insert(0,'.')
import duckdb
from pm_config import settings
con = duckdb.connect(str(settings.duckdb_path), read_only=True)
for t in ['catalogue_tables','catalogue_columns','lineage_edges',
          'pipeline_runs','slo_definitions','schema_snapshots']:
    print(t, con.execute(f'SELECT COUNT(*) FROM {t}').fetchone()[0])
con.close()
"
```

### Step 6: Run ingestion

**Fast mode** — uses fallback text summaries (no Groq API calls, ~30 seconds):

```bash
export PYTHONPATH="."
python ingestion/ingest_pipeline.py \
    --repo-path ./data/pipeline_repo \
    --sql-path  ./data/sql \
    --yaml-path ./data/dags \
    --dbt-path  ./data/dbt_project \
    --skip-summaries \
    --force-reindex
```

**Full mode** — uses Groq `llama3-8b-8192` for LLM summaries (better retrieval quality):

```bash
export PYTHONPATH="."
python ingestion/ingest_pipeline.py \
    --repo-path ./data/pipeline_repo \
    --sql-path  ./data/sql \
    --yaml-path ./data/dags \
    --dbt-path  ./data/dbt_project
```

Verify ChromaDB was populated:

```bash
python -c "
import sys; sys.path.insert(0,'.')
import chromadb
from pm_config import settings
c = chromadb.PersistentClient(path=str(settings.chroma_path))
col = c.get_or_create_collection('pipelinemind', metadata={'hnsw:space':'cosine'})
print('ChromaDB documents:', col.count())
"
```

### Step 7: Start the API backend

```bash
export PYTHONPATH="."
uvicorn api.main:app --host 0.0.0.0 --port 8000 --reload --log-level info
```

Or use the script:

```bash
bash scripts/start_api.sh
```

Verify the API is up:

```bash
curl http://localhost:8000/api/v1/health
```

Expected: `{"status":"ok","environment":"development",...}`

### Step 8: Start the Streamlit UI (new terminal)

```bash
cd /Users/as-mac-1282/Developer/genai_mini/pipelinemind
source .venv/bin/activate
export PYTHONPATH="."
streamlit run ui/app.py --server.port 8501 --server.address localhost
```

Or:

```bash
bash scripts/start_ui.sh
```

Open http://localhost:8501 in your browser.

---

## Installation — Docker Compose

### Build and start

```bash
cd /Users/as-mac-1282/Developer/genai_mini/pipelinemind

# Ensure .env is configured
cp .env.example .env
# Edit .env and set GROQ_API_KEY

docker compose up --build
```

### Services started

| Service | URL | Container Name |
|---|---|---|
| FastAPI backend | http://localhost:8000 | pipelinemind_api |
| Streamlit UI | http://localhost:8501 | pipelinemind_ui |

### Data persistence

The `./data` directory is mounted into both containers, so ChromaDB, DuckDB, and
BM25 index survive container restarts.

### Seeding inside Docker

```bash
docker compose exec api python db/seeder.py
docker compose exec api python ingestion/ingest_pipeline.py \
    --repo-path ./data/pipeline_repo \
    --sql-path  ./data/sql \
    --yaml-path ./data/dags \
    --dbt-path  ./data/dbt_project \
    --skip-summaries --force-reindex
```

---

## Troubleshooting

### Error: `cannot import name 'settings' from 'config'`

The venv has a third-party `config` package installed. PipelineMind uses `pm_config.py`.
Ensure `PYTHONPATH="."` is exported before running any Python command.

```bash
export PYTHONPATH="."
```

### Error: `DuckDBPyConnection has no attribute executescript`

DuckDB does not support `executescript()`. This was fixed in `db/seeder.py` by
executing statements one at a time. If you see this, re-run:

```bash
python db/seeder.py
```

### Error: `ModuleNotFoundError: No module named 'ingestion'`

`conftest.py` handles this for pytest. For direct Python runs, always set:

```bash
export PYTHONPATH="."
```

### Error: `Table with name catalogue_tables does not exist`

The database was not seeded. Run:

```bash
python db/seeder.py
```

### Error: ChromaDB `0 documents` after ingestion

The ingestion script ran against an empty path. Verify the paths exist:

```bash
ls data/pipeline_repo/   # Should show 5 .py files
ls data/sql/             # Should show 3 .sql files
ls data/dags/            # Should show 3 .yml files
ls data/dbt_project/     # Should show manifest.json
```

Then force re-index:

```bash
python ingestion/ingest_pipeline.py --skip-summaries --force-reindex
```

### Groq rate limit errors during ingestion

Use `--skip-summaries` for local testing. Full LLM summaries are only needed for
production-quality retrieval.

### Port already in use

```bash
# Find what is using port 8000
lsof -i :8000
# Kill it
kill -9 <PID>

# Same for 8501
lsof -i :8501
kill -9 <PID>
```

---

## Model Download (First Run)

On first ingestion, sentence-transformers downloads two models to `./data/model_cache/`:

| Model | Size | Purpose |
|---|---|---|
| `all-mpnet-base-v2` | ~420 MB | General text embedding |
| `microsoft/codebert-base` | ~500 MB | Code-specific embedding |
| `ms-marco-MiniLM-L-6-v2` | ~80 MB | Cross-encoder re-ranking |

Total: ~1 GB download. Subsequent runs load from cache.

To pre-warm the cache:

```bash
python -c "
import sys; sys.path.insert(0,'.')
from ingestion.embedders import _get_text_embedder, _get_code_embedder
from retrieval.reranker import _get_cross_encoder
_get_text_embedder()
_get_code_embedder()
_get_cross_encoder()
print('All models cached.')
"
```
MDEOF
log "docs/SETUP.md written"

# ==============================================================================
# 3. docs/ARCHITECTURE.md
# ==============================================================================
step "Writing docs/ARCHITECTURE.md"
cat << 'MDEOF' > docs/ARCHITECTURE.md
# PipelineMind — System Architecture

Deep-dive into every architectural layer, design decision, and data flow.

---

## Table of Contents

- [Three-Tier Overview](#three-tier-overview)
- [Ingestion Pipeline](#ingestion-pipeline)
- [RAG Engine](#rag-engine)
- [Intent Classification and Routing](#intent-classification-and-routing)
- [Agent Loop and MCP Layer](#agent-loop-and-mcp-layer)
- [Data Models](#data-models)
- [Observability](#observability)
- [Security and PII Guardrails](#security-and-pii-guardrails)
- [Technology Decisions](#technology-decisions)

---

## Three-Tier Overview
┌──────────────────────────────────────────────────────────────────┐
│                    TIER 1: Streamlit UI  (8501)                  │
│                                                                  │
│  ┌────────────┐  ┌───────────────────┐  ┌────────────────────┐  │
│  │ Chat Panel │  │ Health Dashboard  │  │ Catalogue Browser  │  │
│  │ (SSE stream│  │ (sparklines, SLO) │  │ (lineage DAG)      │  │
│  └─────┬──────┘  └────────┬──────────┘  └──────────┬─────────┘  │
│        │                  │                         │            │
│  ┌─────▼──────────────────▼─────────────────────────▼─────────┐  │
│  │        MCP Client + Human-in-the-Loop Approval Gate         │  │
│  │        Schema Drift Sidebar Banner (polls every 5 min)      │  │
│  └──────────────────────────┬───────────────────────────────── ┘  │
└─────────────────────────────┼────────────────────────────────────┘
│  HTTP POST / Server-Sent Events
┌─────────────────────────────▼────────────────────────────────────┐
│                 TIER 2: FastAPI Backend  (8000)                  │
│                                                                  │
│  ┌─────────────────┐  ┌──────────────────┐  ┌─────────────────┐ │
│  │  Intent Router  │  │   RAG Engine     │  │  Agent Engine   │ │
│  │  (5 intents)    │  │  (HyDE+RRF+rerank│  │  (Groq tool-use │ │
│  └────────┬────────┘  └────────┬─────────┘  └────────┬────────┘ │
│           └───────────────────┬┘                      │          │
│                               │                       │          │
│  ┌────────────────────────────▼───────────────────────▼────────┐ │
│  │              MCP Server (stdio transport)                    │ │
│  │  6 Tools | 1 Resource (schema drift) | 1 Prompt primitive   │ │
│  └─────────────────────────────────────────────────────────────┘ │
│  ┌─────────────────────────────────────────────────────────────┐  │
│  │  PII Guard Middleware | Structured Logging | Prometheus      │  │
│  └─────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
│
┌─────────────────────────────▼────────────────────────────────────┐
│                    TIER 3: Data Layer                            │
│                                                                  │
│  ┌────────────────┐  ┌─────────────────┐  ┌──────────────────┐  │
│  │   ChromaDB     │  │   BM25 Index    │  │     DuckDB       │  │
│  │ HNSW, 768-dim  │  │  (rank-bm25,    │  │  6 tables:       │  │
│  │ cosine space   │  │   in-memory pkl)│  │  catalogue,      │  │
│  │ persistent     │  │                 │  │  lineage, runs,  │  │
│  └────────────────┘  └─────────────────┘  │  SLOs, snapshots │  │
│                                           └──────────────────┘  │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │  Groq API: llama3-8b | llama3-70b | llama-3.3-70b        │    │
│  └──────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────┘

---

## Ingestion Pipeline

### Flow
Repository Files
│
▼
File Watcher (watchdog) ──── SHA-256 hash comparison ──── Skip unchanged files
│
▼
Chunker Router
├── .py  → ASTChunker     (tree-sitter, function/class boundaries)
├── .sql → SQLChunker     (semicolon-split, DDL/DML/SELECT classification)
├── .yml → YAMLChunker    (Airflow DAG block extraction)
├── .md  → SemanticChunker(heading boundaries + 512-token sliding window)
└── .json→ SemanticChunker(dbt manifest node extraction)
│
▼
MetadataEnricher
├── PII flag (cross-reference pii_registry.json)
├── Git commit hash (subprocess: git log -1 --format=%H)
└── Source type tag
│
▼
SummaryGenerator (Groq llama3-8b-8192, skip_llm=True for fast mode)
└── Fallback: deterministic text from chunk metadata fields
│
▼
ChunkEmbedder
├── Code chunks  → microsoft/codebert-base (768-dim)
└── Text chunks  → all-mpnet-base-v2 (768-dim)
│
▼
┌────┴────┐
│         │
▼         ▼
ChromaDB  BM25Index (rank-bm25, pickled to disk)
(upsert:  (add corpus + chunk_ids, rebuild BM25Okapi)
summary embedded,
raw_implementation in metadata)

### Embed-Summary / Retrieve-Full Pattern

Standard RAG embeds raw code, which degrades recall because user queries are natural
language while code contains identifiers, not descriptions.

PipelineMind instead:

1. Parses each file to AST/statement boundaries
2. Calls Groq to generate a natural language summary + signature per chunk
3. Embeds **only the summary** into ChromaDB
4. Stores the **raw source code** in ChromaDB metadata under `raw_implementation`
5. At retrieval time, pulls the raw code from metadata and injects it into the LLM context

This means the LLM always reasons over real, executable code, but retrieval quality
is driven by natural language summaries that match how engineers ask questions.

---

## RAG Engine

### Full Retrieval Pipeline
User Query
│
▼
IntentClassifier (Groq llama3-70b, zero-shot JSON output)
│
├── GENERAL ──────────────────────────────────► Direct LLM response (no RAG)
│
└── CODE_QA / CATALOGUE / HEALTH / ACTION
│
▼
HyDEProcessor (Groq llama3-70b)
"Generate a hypothetical answer to this question"
Embed the hypothetical answer (not the raw query)
│
▼
┌───────────┴───────────┐
│                       │
▼                       ▼
ChromaRetriever         BM25Retriever
(cosine HNSW, top-20)  (BM25Okapi scores, top-20)
│                       │
└───────────┬───────────┘
▼
RRF Fusion (k=60)
score = Σ [ 1 / (60 + rank_i) ]
Produces top-10 fused list
│
▼
Reranker (cross-encoder/ms-marco-MiniLM-L-6-v2)
Precise (query, doc) pair scoring on top-10
Returns top-5 re-ranked
│
▼
ContextBuilder
├── Token budget enforcement (6000 tokens default)
├── PII redaction on pii_flag=true chunks
├── Raw code injection (retrieve-full pattern)
└── Confidence score: top chunk cosine similarity
│
▼
RetrievalResult {intent, context, chunks, hyde_query}

### Confidence Scoring

- Top chunk cosine similarity score is used as a proxy for retrieval confidence
- If `confidence < 0.6` (configurable), the LLM is instructed to express uncertainty
  rather than generate a hallucinated confident answer
- The confidence score is surfaced in the Streamlit chat UI as a colour-coded metric

---

## Intent Classification and Routing

| Intent | Trigger Pattern | Retrieval Strategy | Response Mode |
|---|---|---|---|
| `CODE_QA` | "How does...", "Why is...", "What does X function do" | Hybrid RAG over code + config | Generated with citations |
| `CATALOGUE` | "What columns...", "Is X PII?", "Show me lineage" | DuckDB metadata query | Structured + narrative |
| `HEALTH` | "Which pipelines failed", "SLO breach", "status of" | Time-series DuckDB query | Dashboard + narrative |
| `ACTION` | "Run DQ check", "What if I drop", "trigger" | MCP tool invocation | Tool result + approval gate |
| `GENERAL` | "Explain watermarks", "What is SCD2" | None (skip RAG entirely) | Direct LLM generation |

The classifier uses Groq `llama3-70b-8192` with a strict JSON-only system prompt.
Falls back to `CODE_QA` on any parse failure.

---

## Agent Loop and MCP Layer

### Agent Iteration Flow
User Message + Context
│
▼
Groq llama-3.3-70b-versatile (function-calling enabled)
│
├── No tool calls ──────────────────────► Final text response
│
└── Tool calls selected
│
▼
Is tool in APPROVAL_REQUIRED_TOOLS?
│
┌───────┴───────┐
│               │
Yes              No
│               │
▼               ▼
Pause loop      Pydantic validation
Return          (validators.py)
approval_required    │
event to UI     ├── Invalid params ──► Return error to LLM (self-correction)
│
└── Valid ──► Execute tool function
│
▼
Tool result appended
to messages list
│
▼
Next iteration
(max 5 iterations)

### MCP Primitives

**Tools** (model-controlled) — Claude decides when and how to call these:
- All 6 action tools listed in the README

**Resources** (app-controlled) — Streamlit polls this every 5 minutes:
- `pipelinemind://schema-drift/latest` — compares `schema_snapshots` baseline
  against current `catalogue_columns` and returns added/dropped/type-changed events

**Prompts** (user-controlled) — slash command template:
- `/diagnose_pipeline {pipeline_id}` — pre-written 5-step diagnostic workflow

### Self-Correction Loop

All tool inputs are validated by Pydantic v2 models in `agent/tools/validators.py`.
When the LLM emits invalid parameters (e.g., a string where an integer is expected),
the validation error is returned directly to the LLM context with a correction hint.
The model then adjusts its next tool call. This prevents crashes and teaches the model
the correct schema through in-context examples.

---

## Data Models

### ChromaDB Document Schema
id:         sha256(source_file + chunk_index)
document:   <LLM-generated natural language summary>   ← this is embedded
embedding:  float[768]
metadata:
source_file:        str   path to the source file
chunk_type:         str   function | method | class | module | sql | yaml | dbt_model
chunk_index:        int
pipeline_name:      str
source_type:        str   python | sql | yaml | markdown | dbt
language:           str
pii_flag:           str   "true" | "false"  (ChromaDB requires string metadata)
tags:               str   comma-separated
content_hash:       str   sha256[:16] of raw_code
git_commit_hash:    str   git log -1 short hash
function_name:      str
class_name:         str
line_start:         str
line_end:           str
raw_implementation: str   ← full source code, injected at retrieval time

### DuckDB Metadata Store

```sql
catalogue_tables    -- table_id, table_name, schema_name, description, domain, pii_flag, tags, row_count
catalogue_columns   -- column_id, table_id, column_name, data_type, pii_class, nullable, retention_days
lineage_edges       -- edge_id, source_table, source_column, target_table, target_column, transformation, pipeline_id
pipeline_runs       -- run_id, pipeline_id, status, start_time, duration_secs, error_message, slo_met
slo_definitions     -- slo_id, pipeline_id, metric_name, target_value, comparison, window_days
schema_snapshots    -- snapshot_id, table_id, table_name, columns_json, captured_at
```

---

## Observability

### Structured Logging

Every request emits a JSON log line via `structlog`:

```json
{
  "event": "request",
  "request_id": "a3f9c12b",
  "method": "POST",
  "path": "/api/v1/chat",
  "status_code": 200,
  "latency_ms": 847.3,
  "timestamp": "2024-03-15T14:23:01.123Z"
}
```

### Prometheus Metrics

Available at `GET /metrics` (Prometheus scrape format):

- `pipelinemind_requests_total{method, endpoint}` — request counter
- `pipelinemind_request_latency_seconds{endpoint}` — latency histogram

### Health Check
GET /api/v1/health
→ {"status": "ok", "environment": "development", "duckdb": "...", "chroma": "..."}

---

## Security and PII Guardrails

### PII Detection

1. At ingestion: `MetadataEnricher` cross-references each chunk's content against
   `data/catalogue/pii_registry.json`. If a chunk references a known PII table+column
   combination, `pii_flag=True` is written to ChromaDB metadata.

2. At retrieval: `ContextBuilder` applies regex-based redaction to any chunk where
   `pii_flag=True`, replacing `email: user@domain.com` patterns with `email: [REDACTED]`
   before the text enters the LLM context.

3. At response: A PII warning banner is shown in the Streamlit chat UI whenever
   `has_pii=True` is returned from the retrieval event.

### Human-in-the-Loop Gate

All state-altering MCP tools (`trigger_dq_check`) require explicit user approval:

1. Agent detects the tool is in `APPROVAL_REQUIRED_TOOLS`
2. Loop pauses, returns `approval_required` SSE event to UI
3. Streamlit renders Allow/Deny buttons via `approval_gate.py`
4. User clicks Allow → `POST /api/v1/chat/approve` with `approved=true`
5. Agent resumes with the approved tool call executed

No production state is mutated without this gate.

---

## Technology Decisions

| Decision | Choice | Rationale |
|---|---|---|
| LLM provider | Groq | Low latency (~200ms), function calling support, cost-effective |
| Vector DB | ChromaDB | Required per SRS; local persistent, HNSW, metadata filtering |
| Sparse retrieval | rank-bm25 | Pure Python, no external service, pairs well with ChromaDB |
| Metadata store | DuckDB | Embedded SQL, fast analytical queries, no server required |
| Embedding models | mpnet + CodeBERT | Domain routing: text for docs, code-specific for Python/SQL |
| Re-ranker | ms-marco-MiniLM-L-6-v2 | Lightweight (6-layer), fast, good MRR on technical corpora |
| Backend framework | FastAPI | Async native, SSE streaming, auto OpenAPI docs, type-safe |
| Frontend | Streamlit | Rapid iteration, session state, custom components |
| Config module | `pm_config.py` | Named to avoid collision with third-party `config` package |
| MCP transport | stdio | Zero network complexity for local demo; child process model |
| Dependency mgmt | pip + venv | Maximum compatibility with macOS Python 3.11.1 |
MDEOF
log "docs/ARCHITECTURE.md written"

# ==============================================================================
# 4. docs/API_REFERENCE.md
# ==============================================================================
step "Writing docs/API_REFERENCE.md"
cat << 'MDEOF' > docs/API_REFERENCE.md
# PipelineMind — API Reference

Base URL: `http://localhost:8000`
Interactive docs: `http://localhost:8000/docs`
All routes prefixed: `/api/v1/`

---

## Authentication

No authentication is required for local development. In production, add an API gateway
or OAuth2 middleware before the FastAPI app.

---

## Chat

### POST /api/v1/chat

Stream a chat response via Server-Sent Events.

**Request body:**

```json
{
  "message": "Why does the orders pipeline use MERGE?",
  "conversation_history": [
    {"role": "user", "content": "..."},
    {"role": "assistant", "content": "..."}
  ],
  "pipeline_filter": "orders",
  "intent_override": null
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `message` | string | Yes | User query (1–4000 chars) |
| `conversation_history` | array | No | Prior turns for multi-turn context |
| `pipeline_filter` | string | No | Filter retrieval to a specific pipeline |
| `intent_override` | string | No | Force a specific intent: `CODE_QA`, `CATALOGUE`, `HEALTH`, `ACTION`, `GENERAL` |

**SSE Event stream:**
event: retrieval_complete
data: {"confidence_score": 0.847, "has_pii": false, "citations": [...], "low_confidence": false}
event: token
data: {"text": "The orders pipeline "}
event: token
data: {"text": "uses MERGE because "}
event: done
data: {"full_response": "...", "tool_calls": [], "iterations": 1, "latency_ms": 923.4}

**Approval required event** (when agent selects a state-altering tool):
event: approval_required
data: {"tool_name": "trigger_dq_check", "tool_args": {"table_name": "orders_fact", "rules_preset": "standard"}, "message": "I need to run..."}

---

### POST /api/v1/chat/approve

Execute or deny a pending tool call after human approval.

**Request body:**

```json
{
  "tool_name": "trigger_dq_check",
  "tool_args": {"table_name": "orders_fact", "rules_preset": "standard"},
  "call_id": "pending",
  "approved": true
}
```

**Response (approved):**

```json
{
  "status": "executed",
  "result": "DQ check passed with score 0.875...",
  "tool_calls": [{"tool": "trigger_dq_check", "approved": true}]
}
```

**Response (denied):**

```json
{"status": "denied", "message": "Tool execution denied by user."}
```

---

## Pipelines

### GET /api/v1/pipelines

List all pipelines with their latest run status and success rates.

**Response:**

```json
[
  {
    "pipeline_id": "orders",
    "total_runs": 150,
    "success_rate": 96.67,
    "last_run": "2024-03-15T14:00:00",
    "last_status": "success"
  }
]
```

---

### GET /api/v1/pipelines/{pipeline_id}/status

Fetch run history and current status for a specific pipeline.

**Query parameters:**

| Parameter | Type | Default | Description |
|---|---|---|---|
| `lookback_hours` | integer | 24 | Hours of history to return |

**Response:**

```json
{
  "status": "success",
  "last_run": "2024-03-15T14:00:00",
  "slo_pct": 96.67,
  "failures": [
    {"run_id": "abc123", "start_time": "2024-03-10T02:00:00", "error": "Connection timeout", "duration_secs": 12.3}
  ],
  "total_runs": 30,
  "pipeline_id": "orders",
  "avg_duration_secs": 87.4
}
```

---

### GET /api/v1/pipelines/{pipeline_id}/slo

SLO adherence report over a rolling window.

**Query parameters:**

| Parameter | Type | Default | Description |
|---|---|---|---|
| `window_days` | integer | 7 | Rolling window in days |

**Response:**

```json
{
  "pipeline_id": "orders",
  "window_days": 7,
  "slo_target": 99.5,
  "actual_pct": 96.67,
  "breach_events": ["run_id_1", "run_id_2"],
  "total_runs": 42,
  "compliant": false
}
```

---

## Data Catalogue

### GET /api/v1/catalogue/tables

List all tables in the data catalogue.

**Response:**

```json
[
  {
    "table_id": "t001",
    "table_name": "orders_fact",
    "schema": "marts",
    "description": "Orders fact table...",
    "domain": "finance",
    "pii_flag": false,
    "tags": ["orders", "finance", "gold"],
    "row_count": 2847293
  }
]
```

---

### GET /api/v1/catalogue/tables/{table_name}

Detailed table metadata including all columns and PII classifications.

**Response:**

```json
{
  "table": {
    "name": "dim_users",
    "schema": "dims",
    "description": "SCD Type-2 users dimension...",
    "domain": "users",
    "pii_flag": true,
    "tags": ["users", "dimension", "pii"],
    "row_count": 185432
  },
  "columns": [
    {"name": "user_id",    "type": "varchar(36)", "pii_class": null,       "nullable": false, "description": "Natural key"},
    {"name": "email",      "type": "varchar(320)","pii_class": "PII_HIGH", "nullable": false, "description": "User email"},
    {"name": "phone_number","type": "varchar(20)","pii_class": "PII_HIGH", "nullable": true,  "description": null}
  ]
}
```

---

### GET /api/v1/catalogue/lineage/{table_name}

Upstream and downstream table lineage graph.

**Query parameters:**

| Parameter | Type | Default | Description |
|---|---|---|---|
| `depth` | integer | 2 | Number of hops to traverse |

**Response:**

```json
{
  "center_table": "orders_fact",
  "depth": 2,
  "nodes": [
    {"table": "orders_fact", "domain": "finance", "pii_flag": false, "row_count": 2847293},
    {"table": "stg_orders",  "domain": "finance", "pii_flag": false, "row_count": 0}
  ],
  "edges": [
    {"source": "stg_orders", "source_column": "order_id", "target": "orders_fact", "target_column": "order_id", "transformation": "merge"}
  ],
  "pii_nodes": [],
  "node_count": 2,
  "edge_count": 1
}
```

---

### GET /api/v1/catalogue/pii

List all PII-tagged tables and columns.

**Query parameters:**

| Parameter | Type | Default | Description |
|---|---|---|---|
| `domain` | string | null | Filter by domain (e.g., `users`, `finance`) |

**Response:**

```json
[
  {
    "table": "dim_users",
    "domain": "users",
    "sensitivity_level": "high",
    "columns": [
      {"column_name": "email",        "pii_class": "PII_HIGH",   "retention_days": 730},
      {"column_name": "phone_number", "pii_class": "PII_HIGH",   "retention_days": 730},
      {"column_name": "full_name",    "pii_class": "PII_MEDIUM", "retention_days": 1095}
    ]
  }
]
```

---

## Data Quality

### POST /api/v1/dq/trigger

Trigger a DQ check against a table (assumes human approval already obtained).

**Request body:**

```json
{
  "table_name": "orders_fact",
  "rules_preset": "standard"
}
```

`rules_preset` options: `minimal`, `standard`, `strict`

**Response:**

```json
{
  "passed": true,
  "failed_rules": [],
  "passed_rules": ["expect_table_row_count_to_be_between", "expect_column_values_to_not_be_null(order_id)"],
  "score": 1.0,
  "run_id": "a3f9c1",
  "table_name": "orders_fact",
  "rules_preset": "standard"
}
```

---

### GET /api/v1/dq/results/{run_id}

Retrieve results for a previous DQ run.

**Response:**

```json
{"run_id": "a3f9c1", "status": "completed", "message": "Results available in GE data docs."}
```

---

## Impact Analysis

### POST /api/v1/impact/analyze

What-If Impact Engine: trace downstream blast radius before a schema change.

**Request body:**

```json
{
  "changed_table": "stg_users",
  "dropped_columns": ["user_id", "email"]
}
```

**Response:**

```json
{
  "changed_table": "stg_users",
  "dropped_columns": ["user_id", "email"],
  "affected_models": ["orders_fact", "sessions_agg"],
  "affected_dashboards": ["revenue_dashboard (Metabase)", "vw_revenue_by_tier"],
  "affected_ml": ["ml_feature_store (user propensity model)"],
  "risk_score": 0.85,
  "recommended_action": "HIGH RISK: Dropping [user_id, email] from stg_users will break...",
  "pii_columns_affected": true,
  "lineage_detail": [
    {"target_table": "orders_fact", "target_column": "customer_id", "source_column": "user_id", "transformation": "direct"}
  ]
}
```

---

## Observability

### GET /api/v1/health

System health check.

**Response:**

```json
{
  "status": "ok",
  "environment": "development",
  "duckdb": "data/pipelinemind.db",
  "chroma": "data/chroma_db"
}
```

---

### GET /api/v1/schema-drift

Latest schema drift events from the MCP Resource polling mechanism.

**Response:**

```json
{
  "drift_events": [],
  "polled_at": "2024-03-15T14:23:01.000Z",
  "status": "clean"
}
```

When drift is detected:

```json
{
  "drift_events": [
    {
      "table": "orders_fact",
      "added_columns": ["new_col"],
      "dropped_columns": [],
      "type_changes": [],
      "baseline_at": "2024-03-15T02:00:00Z",
      "severity": "LOW"
    }
  ],
  "status": "drift_detected"
}
```

---

### GET /metrics

Prometheus metrics endpoint.
pipelinemind_requests_total{method="POST",endpoint="/api/v1/chat"} 42
pipelinemind_request_latency_seconds_bucket{endpoint="/api/v1/chat",le="1.0"} 38
MDEOF
log "docs/API_REFERENCE.md written"

# ==============================================================================
# 5. docs/DEVELOPER_GUIDE.md
# ==============================================================================
step "Writing docs/DEVELOPER_GUIDE.md"
cat << 'MDEOF' > docs/DEVELOPER_GUIDE.md
# PipelineMind — Developer Guide

How to extend, test, and contribute to PipelineMind.

---

## Development Workflow

### Standard run cycle

```bash
cd /Users/as-mac-1282/Developer/genai_mini/pipelinemind
source .venv/bin/activate
export PYTHONPATH="."

# Terminal 1: API with hot-reload
uvicorn api.main:app --host 0.0.0.0 --port 8000 --reload

# Terminal 2: Streamlit
streamlit run ui/app.py --server.port 8501 --server.address localhost

# Terminal 3: re-index after code changes
python ingestion/ingest_pipeline.py --skip-summaries --force-reindex
```

### Run all tests

```bash
pytest tests/ -v --tb=short
```

### Run with coverage

```bash
pytest tests/ --cov=ingestion --cov=retrieval --cov=agent --cov=api \
    --cov-report=term-missing --cov-report=html:htmlcov
open htmlcov/index.html
```

---

## Adding a New MCP Tool

### Step 1: Write the tool function

Create or add to `agent/tools/<domain>_tools.py`:

```python
def my_new_tool(param_a: str, param_b: int = 10) -> dict:
    """
    Docstring describing what this tool does.
    """
    # Tool logic here
    return {"result": "...", "param_a": param_a}
```

### Step 2: Add a Pydantic validator

In `agent/tools/validators.py`:

```python
class MyNewToolInput(BaseModel):
    param_a: str = Field(..., min_length=1)
    param_b: int = Field(default=10, ge=1, le=100)
```

### Step 3: Register in the agent loop

In `agent/agent_loop.py`, add to `TOOL_REGISTRY`:

```python
from agent.tools.my_tools import my_new_tool
from agent.tools.validators import MyNewToolInput

TOOL_REGISTRY["my_new_tool"] = (MyNewToolInput, my_new_tool)
```

Add to `GROQ_TOOLS`:

```python
{
    "type": "function",
    "function": {
        "name": "my_new_tool",
        "description": "Clear description for the LLM to understand when to use this.",
        "parameters": {
            "type": "object",
            "properties": {
                "param_a": {"type": "string"},
                "param_b": {"type": "integer"},
            },
            "required": ["param_a"],
        },
    },
}
```

### Step 4: Register in the MCP server

In `agent/mcp_server.py`, add to `list_tools()` and `call_tool()`.

### Step 5: Add a REST endpoint (optional)

In `api/routers/` add a new router or extend an existing one.

### Step 6: Write tests

```python
# tests/unit/test_my_tool.py
from agent.tools.validators import MyNewToolInput
from pydantic import ValidationError

def test_valid_input():
    v = MyNewToolInput(param_a="test")
    assert v.param_b == 10

def test_invalid_input():
    with pytest.raises(ValidationError):
        MyNewToolInput(param_a="")
```

---

## Adding a New Chunker

### Step 1: Create the chunk dataclass and chunker class

Follow the pattern in `ingestion/chunkers/ast_chunker.py`:

```python
@dataclass
class MyChunk:
    chunk_id: str
    source_file: str
    chunk_type: str = "my_type"
    chunk_index: int = 0
    language: str = "my_lang"
    raw_code: str = ""
    summary: str = ""
    pipeline_name: str = ""
    pii_flag: bool = False
    tags: list[str] = field(default_factory=list)
    git_commit_hash: str = ""
    content_hash: str = ""
    source_type: str = "my_lang"

class MyChunker:
    def chunk(self, file_path: Path, git_commit_hash: str = "") -> list[MyChunk]:
        ...
```

### Step 2: Register the extension in the ingestion pipeline

In `ingestion/ingest_pipeline.py`:

```python
EXTENSION_MAP[".myext"] = "my_lang"
# ...
self.chunkers["my_lang"] = MyChunker()
```

### Step 3: Add a summary prompt

In `ingestion/summary_generator.py`:

```python
SUMMARY_PROMPTS["my_type"] = "Summarise this ... Under 100 words."
```

---

## Adding a New Intent

### Step 1: Add to the Intent enum

In `retrieval/intent_classifier.py`:

```python
class Intent(str, Enum):
    CODE_QA   = "CODE_QA"
    CATALOGUE = "CATALOGUE"
    HEALTH    = "HEALTH"
    ACTION    = "ACTION"
    GENERAL   = "GENERAL"
    MY_NEW_INTENT = "MY_NEW_INTENT"   # add here
```

### Step 2: Update the classifier system prompt

Add a description of the new intent to `_SYSTEM_PROMPT`.

### Step 3: Handle the intent in `HybridRetriever.retrieve()`

Add a branch for the new intent routing in `retrieval/hybrid_retriever.py`.

---

## Environment Variables Reference

All variables are read via `pm_config.py` (Pydantic-Settings). Changing `.env`
takes effect immediately on the next process start (or hot-reload for the API).

```bash
# Change to use stronger model for summaries
GROQ_MODEL_FAST=llama3-70b-8192

# Disable HyDE for faster (but lower recall) retrieval
HYDE_ENABLED=false

# Tighten confidence threshold (model will express uncertainty more often)
CONFIDENCE_THRESHOLD=0.7

# Increase context window for longer code files
MAX_CONTEXT_TOKENS=8000

# Lower agent guard to prevent long chains in demo
AGENT_MAX_ITERATIONS=3
```

---

## Code Style

- Python 3.11+ type hints everywhere
- `from __future__ import annotations` at the top of every module
- Docstrings on every public class and method
- `logging.getLogger(__name__)` — never `print()` in library code
- No bare `except:` — always catch specific exceptions
- Line length: 100 characters (configured in `pyproject.toml`)

---

## Testing Strategy

| Layer | Location | What is tested |
|---|---|---|
| Unit | `tests/unit/` | Chunkers, RRF fusion, Pydantic validators, ContextBuilder |
| Integration | `tests/integration/` | DuckDB tool functions against seeded database |
| Eval | `tests/eval/` | RAG metrics: MRR@5, NDCG@5, Recall@10, latency |

### Writing a unit test

```python
# tests/unit/test_my_feature.py
from __future__ import annotations
import pytest

def test_basic_case():
    from ingestion.chunkers.sql_chunker import SQLChunker
    import tempfile
    from pathlib import Path

    sql = "SELECT * FROM orders; INSERT INTO foo VALUES (1);"
    tmp = Path(tempfile.mktemp(suffix=".sql"))
    tmp.write_text(sql)
    chunks = SQLChunker().chunk(tmp)
    assert len(chunks) == 2
```

### Writing an integration test

```python
# tests/integration/test_my_tool.py
import pytest

@pytest.fixture(autouse=True)
def _check_db():
    from pm_config import settings
    if not settings.duckdb_path.exists():
        pytest.skip("DuckDB not seeded")

def test_tool_returns_expected_shape():
    from agent.tools.pipeline_tools import get_pipeline_status
    result = get_pipeline_status("orders", lookback_hours=720)
    assert "status" in result
    assert isinstance(result["slo_pct"], float)
```

---

## Useful One-Liners

```bash
# Check what is in ChromaDB
python -c "
import sys; sys.path.insert(0,'.')
import chromadb
from pm_config import settings
c = chromadb.PersistentClient(path=str(settings.chroma_path))
col = c.get_collection('pipelinemind')
print(col.count(), 'documents')
print(col.peek(3))
"

# Query ChromaDB directly
python -c "
import sys; sys.path.insert(0,'.')
import chromadb
from pm_config import settings
from ingestion.embedders import ChunkEmbedder
c = chromadb.PersistentClient(path=str(settings.chroma_path))
col = c.get_collection('pipelinemind')
emb = ChunkEmbedder().embed_query('orders pipeline merge strategy')
results = col.query(query_embeddings=[emb], n_results=3)
for doc in results['documents'][0]:
    print(doc[:200])
    print('---')
"

# Inspect DuckDB tables
python -c "
import sys; sys.path.insert(0,'.')
import duckdb
from pm_config import settings
con = duckdb.connect(str(settings.duckdb_path), read_only=True)
print(con.execute('SELECT * FROM catalogue_tables LIMIT 5').df())
con.close()
"

# Test a tool directly
python -c "
import sys; sys.path.insert(0,'.')
from agent.tools.lineage_tools import analyze_lineage_impact
import json
result = analyze_lineage_impact('dim_users', ['user_id'])
print(json.dumps(result, indent=2))
"

# Test the full retrieval pipeline
python -c "
import sys; sys.path.insert(0,'.')
from retrieval.hybrid_retriever import HybridRetriever
r = HybridRetriever()
result = r.retrieve('Why does the orders pipeline use MERGE strategy?')
print('Intent:', result.intent)
print('Confidence:', result.context.confidence_score)
print('Chunks used:', len(result.context.chunks_used))
print(result.context.context_text[:500])
"

# Re-seed and re-index in one command
python db/seeder.py && python ingestion/ingest_pipeline.py \
    --skip-summaries --force-reindex \
    --repo-path ./data/pipeline_repo \
    --sql-path  ./data/sql \
    --yaml-path ./data/dags \
    --dbt-path  ./data/dbt_project
```
MDEOF
log "docs/DEVELOPER_GUIDE.md written"

# ==============================================================================
# 6. docs/BASH_COMMANDS.md
# ==============================================================================
step "Writing docs/BASH_COMMANDS.md"
cat << 'MDEOF' > docs/BASH_COMMANDS.md
# PipelineMind — Bash Commands Reference

All commands assume you are in the project root:
```bash
cd /Users/as-mac-1282/Developer/genai_mini/pipelinemind
```

---

## Environment Setup

```bash
# Activate virtual environment
source .venv/bin/activate

# Always set PYTHONPATH before any Python command
export PYTHONPATH="."

# Verify environment
python -c "from pm_config import settings; print(settings.groq_model_agent)"
```

---

## Database

```bash
# Seed DuckDB (creates/resets all 6 tables)
python db/seeder.py

# Verify seeding
python -c "
import sys; sys.path.insert(0,'.')
import duckdb
from pm_config import settings
con = duckdb.connect(str(settings.duckdb_path), read_only=True)
for t in ['catalogue_tables','catalogue_columns','lineage_edges',
          'pipeline_runs','slo_definitions','schema_snapshots']:
    n = con.execute(f'SELECT COUNT(*) FROM {t}').fetchone()[0]
    print(f'{t:<30} {n} rows')
con.close()
"

# Using the script
bash scripts/seed_db.sh
```

---

## Ingestion

```bash
# Fast ingestion — no Groq API calls, fallback summaries (~30 seconds)
export PYTHONPATH="."
python ingestion/ingest_pipeline.py \
    --repo-path ./data/pipeline_repo \
    --sql-path  ./data/sql \
    --yaml-path ./data/dags \
    --dbt-path  ./data/dbt_project \
    --skip-summaries \
    --force-reindex

# Full LLM ingestion — Groq summaries, better retrieval quality
python ingestion/ingest_pipeline.py \
    --repo-path ./data/pipeline_repo \
    --sql-path  ./data/sql \
    --yaml-path ./data/dags \
    --dbt-path  ./data/dbt_project

# Using scripts
bash scripts/ingest_fast.sh
bash scripts/ingest.sh

# Verify ChromaDB population
python -c "
import sys; sys.path.insert(0,'.')
import chromadb
from pm_config import settings
c = chromadb.PersistentClient(path=str(settings.chroma_path))
col = c.get_or_create_collection('pipelinemind', metadata={'hnsw:space':'cosine'})
print('ChromaDB documents:', col.count())
"

# Wipe and re-index (clears ChromaDB and BM25 state)
rm -rf data/chroma_db data/bm25_index.pkl data/.file_hashes.json
python db/seeder.py
bash scripts/ingest_fast.sh
```

---

## API Backend

```bash
# Start with hot-reload (development)
export PYTHONPATH="."
uvicorn api.main:app --host 0.0.0.0 --port 8000 --reload --log-level info

# Start without reload (production-like)
uvicorn api.main:app --host 0.0.0.0 --port 8000 --workers 1

# Using script
bash scripts/start_api.sh

# Health check
curl http://localhost:8000/api/v1/health

# Test chat endpoint (non-streaming)
curl -X POST http://localhost:8000/api/v1/chat \
    -H "Content-Type: application/json" \
    -d '{"message": "What pipelines are available?", "conversation_history": []}' \
    --no-buffer

# List all pipelines
curl http://localhost:8000/api/v1/pipelines | python -m json.tool

# Pipeline status
curl "http://localhost:8000/api/v1/pipelines/orders/status?lookback_hours=72" | python -m json.tool

# SLO report
curl "http://localhost:8000/api/v1/pipelines/orders/slo?window_days=30" | python -m json.tool

# List catalogue tables
curl http://localhost:8000/api/v1/catalogue/tables | python -m json.tool

# Table detail
curl http://localhost:8000/api/v1/catalogue/tables/dim_users | python -m json.tool

# Lineage graph
curl "http://localhost:8000/api/v1/catalogue/lineage/orders_fact?depth=2" | python -m json.tool

# PII tables
curl http://localhost:8000/api/v1/catalogue/pii | python -m json.tool

# What-If impact analysis
curl -X POST http://localhost:8000/api/v1/impact/analyze \
    -H "Content-Type: application/json" \
    -d '{"changed_table": "stg_users", "dropped_columns": ["user_id", "email"]}' \
    | python -m json.tool

# Schema drift check
curl http://localhost:8000/api/v1/schema-drift | python -m json.tool

# Prometheus metrics
curl http://localhost:8000/metrics

# OpenAPI JSON spec
curl http://localhost:8000/openapi.json | python -m json.tool
```

---

## Streamlit UI

```bash
# Start UI
export PYTHONPATH="."
streamlit run ui/app.py \
    --server.port 8501 \
    --server.address localhost \
    --server.headless false \
    --browser.gatherUsageStats false

# Using script
bash scripts/start_ui.sh

# Start headless (for server deployment)
streamlit run ui/app.py \
    --server.port 8501 \
    --server.address 0.0.0.0 \
    --server.headless true
```

---

## Testing

```bash
# All tests
export PYTHONPATH="."
pytest tests/ -v --tb=short

# Unit tests only
pytest tests/unit/ -v --tb=short

# Integration tests only (requires seeded DB)
pytest tests/integration/ -v --tb=short

# Specific test file
pytest tests/unit/test_chunkers.py -v

# Specific test
pytest tests/unit/test_rrf_fusion.py::test_rrf_combines_both_lists -v

# With coverage
pytest tests/ --cov=ingestion --cov=retrieval --cov=agent --cov=api \
    --cov-report=term-missing --cov-report=html:htmlcov

# Using script
bash scripts/run_tests.sh
```

---

## Docker

```bash
# Build and start all services
docker compose up --build

# Start in background
docker compose up -d

# View logs (API)
docker compose logs -f api

# View logs (UI)
docker compose logs -f ui

# Seed and ingest inside container
docker compose exec api python db/seeder.py
docker compose exec api bash -c "export PYTHONPATH=. && python ingestion/ingest_pipeline.py \
    --repo-path ./data/pipeline_repo \
    --sql-path  ./data/sql \
    --yaml-path ./data/dags \
    --dbt-path  ./data/dbt_project \
    --skip-summaries --force-reindex"

# Rebuild single service
docker compose build api
docker compose up -d api

# Stop all
docker compose down

# Stop and remove volumes
docker compose down -v

# Check running containers
docker compose ps
```

---

## Debugging

```bash
# Test a single MCP tool directly
export PYTHONPATH="."
python -c "
from agent.tools.pipeline_tools import get_pipeline_status
import json; print(json.dumps(get_pipeline_status('orders', 168), indent=2, default=str))
"

python -c "
from agent.tools.lineage_tools import analyze_lineage_impact
import json; print(json.dumps(analyze_lineage_impact('dim_users', ['user_id']), indent=2))
"

python -c "
from agent.tools.catalogue_tools import search_pii_tables
import json; print(json.dumps(search_pii_tables(), indent=2))
"

# Test intent classifier
python -c "
import sys; sys.path.insert(0,'.')
from retrieval.intent_classifier import IntentClassifier
clf = IntentClassifier()
for q in [
    'Why does the orders pipeline use MERGE?',
    'What PII columns exist in dim_users?',
    'Did the orders pipeline fail today?',
    'What happens if I drop user_id from stg_users?',
    'What is incremental loading?',
]:
    intent, conf = clf.classify(q)
    print(f'{intent.value:<12} ({conf:.2f})  {q[:60]}')
"

# Test HyDE
python -c "
import sys; sys.path.insert(0,'.')
from retrieval.hyde import HyDEProcessor
hypo = HyDEProcessor().generate('Why does the orders pipeline use MERGE?')
print(hypo)
"

# Test full retrieval pipeline
python -c "
import sys; sys.path.insert(0,'.')
from retrieval.hybrid_retriever import HybridRetriever
r = HybridRetriever()
result = r.retrieve('Why does the orders pipeline use MERGE strategy?')
print('Intent:    ', result.intent)
print('HyDE query:', result.hyde_query[:100])
print('Confidence:', result.context.confidence_score)
print('Chunks:    ', len(result.context.chunks_used))
print('Has PII:   ', result.context.has_pii)
print()
print(result.context.context_text[:600])
"

# Check port usage
lsof -i :8000
lsof -i :8501

# Kill process on port
lsof -ti :8000 | xargs kill -9

# Watch API logs in real time
tail -f logs/*.log 2>/dev/null || echo "No log files yet"
```

---

## Maintenance

```bash
# Update all pip packages
source .venv/bin/activate
pip list --outdated
pip install --upgrade groq chromadb sentence-transformers

# Clear model cache (forces re-download)
rm -rf data/model_cache/

# Clear ChromaDB (forces full re-index)
rm -rf data/chroma_db/ data/bm25_index.pkl data/.file_hashes.json

# Clear DuckDB (forces re-seed)
rm -f data/pipelinemind.db

# Full reset (wipe everything, start fresh)
rm -rf data/chroma_db/ data/bm25_index.pkl data/.file_hashes.json data/pipelinemind.db
python db/seeder.py
bash scripts/ingest_fast.sh

# Check disk usage
du -sh data/chroma_db/ data/pipelinemind.db data/model_cache/ data/bm25_index.pkl 2>/dev/null
```
MDEOF
log "docs/BASH_COMMANDS.md written"

# ==============================================================================
# 7. docs/CHANGELOG.md
# ==============================================================================
step "Writing docs/CHANGELOG.md"
cat << 'MDEOF' > docs/CHANGELOG.md
# Changelog

All notable changes to PipelineMind are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [0.2.0] — 2024-05-11 — Fix Release

### Fixed

- **DuckDB seeder** — replaced `executescript()` (not available in DuckDB 1.x)
  with per-statement `execute()` calls in `db/seeder.py`
- **Config name clash** — renamed `config.py` to `pm_config.py` to avoid collision
  with the third-party `config` package installed in the venv; all import sites patched
- **pytest module discovery** — added `conftest.py` at project root to insert the
  project directory at the front of `sys.path`; added `pythonpath = ["."]` to
  `pyproject.toml`
- **DuckDB schema** — removed `UNIQUE` constraint on `table_name` and `pipeline_id`
  columns that caused `INSERT OR REPLACE` failures; DuckDB 1.x handles upserts
  differently from SQLite
- **Pipelines router** — replaced `LAST()` window aggregate (not in DuckDB 1.x) with
  a `ROW_NUMBER() OVER (PARTITION BY ...)` subquery in `api/routers/pipelines.py`
- **Seeder timestamp shifting** — pipeline run timestamps are now shifted forward so
  the most-recent fixture run lands at `datetime.utcnow()`, ensuring rolling-window
  queries (`lookback_hours=24`) always find data regardless of fixture age
- **Validators Pydantic v2 compatibility** — changed `min_items=1` to `min_length=1`
  on `list[str]` fields in `AnalyzeLineageImpactInput`
- **Embedders import** — changed `from sentence_transformers import SentenceTransformer, models`
  to use `from sentence_transformers.sentence_transformer import modules as st_modules`
  for compatibility with sentence-transformers 3.x
- **Chat router JSON serialisation** — added `_json_default` fallback serialiser for
  `datetime` and `date` objects in SSE event payloads
- **Approval gate** — persists tool result as a chat message before calling
  `st.rerun()` so the result is not lost on page reload; timeout increased from 30s
  to 60s
- **MCP resources** — added `db_not_seeded` and `db_error` guard returns in
  `get_schema_drift_events()` so the sidebar never crashes when the DB is absent
- **Scripts** — added `export PYTHONPATH="."` and auto-seed guard
  (`[[ -f data/pipelinemind.db ]] || python db/seeder.py`) to all shell scripts
- **pyproject.toml** — set `log_level = "WARNING"` and added `filterwarnings` to
  suppress Pydantic v2 deprecation noise and sentence-transformers warnings in tests

### Changed

- `db/schema.sql` — removed all `UNIQUE` constraints to be compatible with
  DuckDB 1.x `INSERT OR REPLACE` semantics
- `db/seeder.py` — rewrote `_execute_schema()` to split SQL on semicolons and
  execute one statement at a time

---

## [0.1.0] — 2024-05-10 — Initial Release

### Added

- Full three-tier architecture: Streamlit UI → FastAPI → ChromaDB + DuckDB + Groq
- Ingestion pipeline with 4 chunkers (AST, SQL, YAML, Markdown/dbt)
- Embed-summary / retrieve-full RAG pattern
- Dual embedders: `all-mpnet-base-v2` (text) + `microsoft/codebert-base` (code)
- Hybrid retrieval: ChromaDB dense + BM25 sparse, fused via Reciprocal Rank Fusion
- Cross-encoder re-ranking: `ms-marco-MiniLM-L-6-v2`
- HyDE (Hypothetical Document Embedding) query processing
- Intent classifier: 5 intents (CODE_QA, CATALOGUE, HEALTH, ACTION, GENERAL)
- Groq function-calling agent loop with max 5 iterations
- 6 MCP tools: trigger_dq_check, get_pipeline_status, get_lineage_graph,
  analyze_lineage_impact, search_pii_tables, get_slo_report
- MCP Resource: schema drift polling every 5 minutes
- MCP Prompt: `/diagnose_pipeline {pipeline_id}` slash command
- Pydantic v2 tool validators with self-correction loop
- Human-in-the-loop approval gate for state-altering tools
- PII guardrails: detection at ingestion, redaction at retrieval, warning in UI
- Confidence scoring: low confidence triggers explicit uncertainty communication
- 14 REST endpoints on FastAPI with SSE streaming
- Streamlit UI: chat panel, health dashboard, catalogue browser, lineage DAG
- Schema drift sidebar banner
- structlog JSON logging + Prometheus metrics
- Docker Compose single-command startup
- DuckDB metadata store with 6 tables + synthetic fixtures
- 5 realistic synthetic Python ETL pipelines
- 3 SQL schema files, 3 Airflow YAML DAGs, dbt manifest + catalog
- 30-day synthetic pipeline run history
- Unit tests for chunkers, RRF fusion, validators, context builder
- Integration tests for all 6 MCP tools against seeded DuckDB
MDEOF
log "docs/CHANGELOG.md written"

# ==============================================================================
# 8. docs/CONTRIBUTING.md
# ==============================================================================
step "Writing docs/CONTRIBUTING.md"
cat << 'MDEOF' > docs/CONTRIBUTING.md
# Contributing to PipelineMind

---

## Getting Started

1. Fork or clone the repository
2. Follow the setup in `docs/SETUP.md`
3. Create a feature branch: `git checkout -b feature/my-feature`
4. Make changes, add tests, verify all tests pass
5. Submit a pull request

---

## Branch Naming

| Type | Pattern | Example |
|---|---|---|
| Feature | `feature/<name>` | `feature/add-slack-notification-tool` |
| Bug fix | `fix/<name>` | `fix/duckdb-seeder-executescript` |
| Documentation | `docs/<name>` | `docs/api-reference-update` |
| Chore | `chore/<name>` | `chore/upgrade-sentence-transformers` |

---

## Commit Messages

Format: `<type>(<scope>): <description>`

Types: `feat`, `fix`, `docs`, `test`, `refactor`, `chore`

Examples:
feat(agent): add Slack notification MCP tool
fix(seeder): replace executescript with per-statement execute for DuckDB 1.x
docs(api): add missing /impact/analyze request body example
test(chunkers): add YAML chunker edge case for missing slo block
refactor(retrieval): extract confidence score calculation into helper method
chore(deps): upgrade sentence-transformers to 3.1.0

---

## Pull Request Checklist

- [ ] All existing tests pass: `pytest tests/ -v`
- [ ] New functionality has unit tests in `tests/unit/`
- [ ] New tool integrations have integration tests in `tests/integration/`
- [ ] Type hints on all new functions and methods
- [ ] Docstrings on all new public classes and methods
- [ ] `CHANGELOG.md` entry added under `[Unreleased]`
- [ ] `.env.example` updated if new environment variables were added
- [ ] No secrets committed (API keys, credentials)
- [ ] `export PYTHONPATH="."` works for all new scripts

---

## Code Standards

### Python

```python
# Good — explicit types, docstring, logger, structured return
def get_pipeline_status(pipeline_id: str, lookback_hours: int = 24) -> dict[str, Any]:
    """
    Fetch current run status and history for a pipeline.

    Args:
        pipeline_id: Identifier matching pipeline_runs.pipeline_id in DuckDB.
        lookback_hours: How many hours back to query (1-720).

    Returns:
        Dict with keys: status, last_run, slo_pct, failures, total_runs.
    """
    logger.info("get_pipeline_status | pipeline=%s lookback=%dh", pipeline_id, lookback_hours)
    ...
```

### Tests

```python
# Good — clear test name, single assertion per test, no external dependencies
def test_rrf_document_in_both_lists_ranks_higher():
    dense  = [_make_chunk("shared", 0.9), _make_chunk("dense_only", 0.8)]
    sparse = [_make_chunk("shared", 0.85)]
    result = reciprocal_rank_fusion(dense, sparse, top_n=2)
    assert result[0].chunk_id == "shared"
```

---

## Where to Add New Features

| Feature type | Location |
|---|---|
| New MCP tool | `agent/tools/<domain>_tools.py` + `validators.py` + `agent_loop.py` |
| New chunker | `ingestion/chunkers/<type>_chunker.py` + `ingest_pipeline.py` |
| New API endpoint | `api/routers/<domain>.py` + `api/models/__init__.py` |
| New UI page | `ui/pages/<N>_<Name>.py` + `ui/components/<component>.py` |
| New intent | `retrieval/intent_classifier.py` + `hybrid_retriever.py` |
| New DuckDB table | `db/schema.sql` + `db/seeder.py` + fixture JSON |

---

## Reporting Issues

When reporting a bug, include:

1. Python version (`python3 --version`)
2. The exact error message and traceback
3. The command that triggered the error
4. Output of `python -c "from pm_config import settings; print(settings.duckdb_path)"`
5. ChromaDB document count: `python -c "import sys,chromadb; sys.path.insert(0,'.'); from pm_config import settings; c=chromadb.PersistentClient(str(settings.chroma_path)); print(c.get_or_create_collection('pipelinemind').count())"`
MDEOF
log "docs/CONTRIBUTING.md written"

# ==============================================================================
# 9. docs/HANDOVER.md
# ==============================================================================
step "Writing docs/HANDOVER.md"
cat << 'MDEOF' > docs/HANDOVER.md
# PipelineMind — LLM Context Handover Document

This document is designed to be ingested by a new LLM session to resume work
on PipelineMind without any prior context. Read every section.

---

## Project Identity

- **Name:** PipelineMind
- **Version:** 0.2.0
- **Purpose:** Production-grade RAG-powered Data Engineering AI assistant with agentic MCP tools
- **Root path:** `/Users/as-mac-1282/Developer/genai_mini/pipelinemind`
- **Python:** 3.11.1 (venv at `.venv/`)
- **LLM provider:** Groq API (`pm_config.py` has three model tiers)
- **Status:** All tests passing, all scripts working, API and UI functional

---

## Critical Configuration Facts

1. The settings module is `pm_config.py`, NOT `config.py`. There is a third-party
   `config` package in the venv that would be imported instead. Every Python file
   uses `from pm_config import settings`.

2. Every Python command must be run with `export PYTHONPATH="."` set, or the
   local packages (ingestion, retrieval, agent, api) will not be found.

3. DuckDB 1.x does NOT have `executescript()`. The seeder uses per-statement
   `execute()` calls. DuckDB 1.x also does not support the `LAST()` window
   aggregate — use `ROW_NUMBER() OVER (PARTITION BY ...)` instead.

4. The `conftest.py` at project root inserts the project root into `sys.path`
   before the venv site-packages, so pytest resolves `pm_config` correctly.

5. ChromaDB metadata values must be strings. Booleans are stored as `"true"`/`"false"`.

6. Sentence-transformers 3.x changed the import path for modules.
   Use: `from sentence_transformers.sentence_transformer import modules as st_modules`

---

## Working File Tree (Complete)
pipelinemind/
├── pm_config.py                     SETTINGS — import from here only
├── conftest.py                      pytest sys.path fix
├── pyproject.toml                   deps + pytest config
├── docker-compose.yml
├── .env                             SECRETS — gitignored
├── .env.example
│
├── ingestion/
│   ├── chunkers/
│   │   ├── ast_chunker.py           tree-sitter Python; CodeChunk dataclass
│   │   ├── sql_chunker.py           semicolon-split; SQLChunk dataclass
│   │   ├── yaml_chunker.py          Airflow YAML blocks; YAMLChunk dataclass
│   │   └── semantic_chunker.py      Markdown headings + dbt JSON; SemanticChunk
│   ├── summary_generator.py         Groq llama3-8b; fallback text on failure
│   ├── embedders.py                 ChunkEmbedder: mpnet for text, CodeBERT for code
│   ├── metadata_enricher.py         PII flag + git hash; reads pii_registry.json
│   ├── watcher.py                   watchdog; emits FileChangeEvent to queue
│   └── ingest_pipeline.py           CLI entry: --skip-summaries --force-reindex
│
├── retrieval/
│   ├── chroma_retriever.py          ChromaRetriever; returns list[RetrievedChunk]
│   ├── bm25_retriever.py            BM25Retriever; loads pickled index
│   ├── rrf_fusion.py                reciprocal_rank_fusion(dense, sparse, k=60)
│   ├── reranker.py                  Reranker; ms-marco-MiniLM-L-6-v2
│   ├── hyde.py                      HyDEProcessor; Groq llama3-70b
│   ├── context_builder.py           ContextBuilder; token budget + PII redact
│   ├── intent_classifier.py         IntentClassifier; Intent enum; 5 intents
│   └── hybrid_retriever.py          HybridRetriever.retrieve() → RetrievalResult
│
├── agent/
│   ├── agent_loop.py                AgentLoop.run(); Groq function-calling; max 5 iters
│   ├── mcp_server.py                MCP SDK server; 6 Tools + 1 Resource + 1 Prompt
│   ├── mcp_resources.py             get_schema_drift_events(); safe guards for missing DB
│   └── tools/
│       ├── validators.py            Pydantic v2 models for all 6 tool inputs
│       ├── dq_tools.py              trigger_dq_check(); DuckDB-backed GE simulation
│       ├── pipeline_tools.py        get_pipeline_status(); get_slo_report()
│       ├── lineage_tools.py         get_lineage_graph(); analyze_lineage_impact()
│       └── catalogue_tools.py       search_pii_tables()
│
├── api/
│   ├── main.py                      FastAPI app; middleware; 14 route groups
│   ├── middleware/
│   │   ├── logging.py               StructuredLoggingMiddleware; structlog JSON
│   │   └── pii_guard.py             PIIGuardMiddleware; X-PII-Warning header
│   ├── models/__init__.py        ChatRequest, ToolApprovalRequest, etc.
│   └── routers/
│       ├── chat.py                  POST /api/v1/chat SSE; POST /chat/approve
│       ├── pipelines.py             GET /pipelines; /pipelines/{id}/status; /slo
│       ├── catalogue.py             GET /catalogue/tables; /tables/{n}; /lineage/{t}; /pii
│       ├── dq.py                    POST /dq/trigger; GET /dq/results/{run_id}
│       └── impact.py                POST /impact/analyze
│
├── ui/
│   ├── app.py                       st.set_page_config; sidebar nav; render_chat_panel
│   ├── components/
│   │   ├── chat_panel.py            _stream_chat(); SSE parsing; approval pending state
│   │   ├── health_dashboard.py      pipeline list + sparkline metrics
│   │   ├── lineage_graph.py         streamlit-agraph; color codes PII nodes
│   │   ├── approval_gate.py         Allow/Deny buttons; POST /chat/approve; 60s timeout
│   │   └── schema_drift_banner.py   polls /schema-drift every 300s; sidebar warning
│   └── pages/
│       ├── 01_Chat.py
│       ├── 02_Health.py
│       └── 03_Catalogue.py
│
├── data/
│   ├── pipeline_repo/               5 Python ETL scripts (orders, users, inventory, sessions, metrics)
│   ├── sql/                         orders_schema.sql, users_schema.sql, analytics_views.sql
│   ├── dags/                        orders_dag.yml, users_dag.yml, metrics_dag.yml
│   ├── dbt_project/                 manifest.json (5 models), catalog.json
│   ├── catalogue/                   tables_metadata.json (8), pii_registry.json (6), lineage_edges.json (9)
│   ├── run_logs/                    pipeline_runs.json (150 runs, timestamps shifted to now)
│   ├── schema_snapshots/            baseline.json (3 tables)
│   ├── chroma_db/                   persistent HNSW index
│   ├── pipelinemind.db              DuckDB file
│   └── bm25_index.pkl               pickled BM25Okapi + corpus + chunk_ids
│
├── db/
│   ├── schema.sql                   6 CREATE TABLE IF NOT EXISTS (no UNIQUE constraints)
│   └── seeder.py                    _execute_schema() + 6 seed functions + timestamp shift
│
├── tests/
│   ├── unit/                        test_chunkers, test_rrf_fusion, test_validators, test_context_builder
│   └── integration/                 test_duckdb_tools (7 tests, all require seeded DB)
│
├── scripts/
│   ├── start_api.sh                 export PYTHONPATH + auto-seed guard + uvicorn
│   ├── start_ui.sh                  export PYTHONPATH + streamlit run
│   ├── ingest.sh                    export PYTHONPATH + auto-seed guard + full ingestion
│   ├── ingest_fast.sh               export PYTHONPATH + auto-seed guard + --skip-summaries
│   ├── seed_db.sh                   python db/seeder.py
│   └── run_tests.sh                 pytest tests/ -v --tb=short
│
└── docs/
├── SETUP.md
├── ARCHITECTURE.md
├── API_REFERENCE.md
├── DEVELOPER_GUIDE.md
├── BASH_COMMANDS.md
├── CHANGELOG.md
├── CONTRIBUTING.md
└── HANDOVER.md (this file)

---

## Key Data Flows

### Ingestion (one-time, then incremental)
Files → SHA-256 hash → skip unchanged → chunker → enricher → summary (Groq) →
embed (mpnet/CodeBERT) → ChromaDB.upsert (summary embedded, raw_code in metadata) →
BM25.add (corpus + chunk_ids) → pickle BM25 to disk

### Chat request
POST /api/v1/chat →
IntentClassifier (Groq 70b) →
HyDEProcessor (Groq 70b) →
ChromaRetriever (top-20) + BM25Retriever (top-20) →
RRF fusion (top-10) →
Reranker (top-5) →
ContextBuilder (token budget, PII redact, raw code inject) →
AgentLoop (Groq 70b function-calling, max 5 iter) →
SSE stream to Streamlit

### Tool approval flow
Agent selects trigger_dq_check →
AgentLoop returns approval_required SSE event →
Streamlit renders Allow/Deny buttons →
User clicks Allow →
POST /api/v1/chat/approve {approved: true} →
AgentLoop resumes with pending_approval →
tool executed, result returned

---

## Known Limitations

| Limitation | Impact | Mitigation in place |
|---|---|---|
| ChromaDB 0 docs before ingestion | All retrieval returns empty | ingest_fast.sh auto-seeds + indexes |
| Groq rate limits on llama3-8b | Summary generation throttled | tenacity retry + 0.3s sleep between calls |
| BM25 re-built from scratch on reindex | Memory spike on large repos | Batch processing in ingest_pipeline.py |
| sentence-transformers model download | ~1 GB on first run | data/model_cache/ persists across runs |
| MCP SDK stdio transport | Not suitable for multi-user production | StreamableHTTP noted as production roadmap |
| GE DQ checks are simulated | No real Great Expectations suites | DuckDB-backed simulation returns realistic output |

---

## What Was Built vs What Remains

### Completed (v0.2.0)

- All 7 phases of the SRS implementation roadmap
- All 14 REST endpoints
- All 6 MCP tools + 1 Resource + 1 Prompt
- Full hybrid RAG pipeline (HyDE + Dense + Sparse + RRF + Reranker)
- Streamlit UI with all 3 pages + 5 components
- Docker Compose setup
- Unit + integration tests
- Full documentation suite

### Not Yet Built (Phase 8+ / future work)

- RAG evaluation notebook (`notebooks/RAG_Pipeline_Evaluation.ipynb`) — MRR@5, NDCG@5
- Real Airflow/dbt integration (currently uses synthetic fixtures)
- Fine-tuned code embedder on DE-specific corpus
- Multi-tenant authentication layer
- StreamableHTTP MCP transport for remote deployment
- Prometheus + Grafana monitoring stack
- Real Great Expectations suite against live DuckDB tables

---

## How to Resume Development

1. `cd /Users/as-mac-1282/Developer/genai_mini/pipelinemind`
2. `source .venv/bin/activate && export PYTHONPATH="."`
3. Verify state: `pytest tests/ -v --tb=short`
4. If DuckDB is missing: `python db/seeder.py`
5. If ChromaDB is empty: `bash scripts/ingest_fast.sh`
6. Start API: `bash scripts/start_api.sh` (Terminal 1)
7. Start UI: `bash scripts/start_ui.sh` (Terminal 2)
8. Begin development against the running system

Always add `from pm_config import settings` (not `from config import settings`).
Always run Python with `export PYTHONPATH="."`.
MDEOF
log "docs/HANDOVER.md written"

# ==============================================================================
# VERIFY ALL DOCS WERE WRITTEN
# ==============================================================================
step "Verifying documentation"

echo ""
echo "Documentation files created:"
find "$DOCS_DIR" -name "*.md" | sort | while read -r f; do
    lines=$(wc -l < "$f")
    size=$(wc -c < "$f" | awk '{printf "%.1fK", $1/1024}')
    printf "  %-40s  %4d lines  %6s\n" "${f#$PROJECT_DIR/}" "$lines" "$size"
done

readme_lines=$(wc -l < "$PROJECT_DIR/README.md")
printf "  %-40s  %4d lines\n" "README.md" "$readme_lines"

echo ""
total_docs=$(find "$DOCS_DIR" -name "*.md" | wc -l | tr -d ' ')
echo "Total: $total_docs documentation files + README.md"

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Documentation generation complete${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Files written:"
echo "  README.md                  — Project overview, quick start, structure"
echo "  docs/SETUP.md              — Full installation walkthrough + troubleshooting"
echo "  docs/ARCHITECTURE.md       — Deep-dive system design + all data flows"
echo "  docs/API_REFERENCE.md      — All 14 endpoints with request/response examples"
echo "  docs/DEVELOPER_GUIDE.md    — How to extend tools, chunkers, intents + one-liners"
echo "  docs/BASH_COMMANDS.md      — Every command for every task in one place"
echo "  docs/CHANGELOG.md          — v0.1.0 + v0.2.0 fix release documented"
echo "  docs/CONTRIBUTING.md       — Branch naming, PR checklist, code standards"
echo "  docs/HANDOVER.md           — LLM-ready context handover document"
echo ""
echo "  View any doc:"
echo "  cat $PROJECT_DIR/docs/BASH_COMMANDS.md"
echo "  cat $PROJECT_DIR/docs/SETUP.md"
echo "  cat $PROJECT_DIR/README.md"
echo ""