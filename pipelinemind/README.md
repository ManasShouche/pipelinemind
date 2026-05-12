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

```
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
```

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

```
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
│   ├── models/__init__.py    # Pydantic request/response models
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
```

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

```
API: http://localhost:8000
UI:  http://localhost:8501
```

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
