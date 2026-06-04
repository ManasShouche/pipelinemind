# PipelineMind

> RAG-Powered Data Engineering Assistant

PipelineMind is a production-grade conversational AI assistant for Data Engineers. It combines a hybrid RAG pipeline (HyDE → Dense + Sparse → RRF → Cross-encoder → Graph RAG) with a live agentic loop over six MCP tools — giving engineers a single chat surface to understand codebases, explore data catalogues, monitor pipeline health, and trigger quality checks.

[![Python 3.11+](https://img.shields.io/badge/python-3.11+-blue.svg)](https://www.python.org/)
[![FastAPI](https://img.shields.io/badge/FastAPI-0.111-green.svg)](https://fastapi.tiangolo.com/)
[![Streamlit](https://img.shields.io/badge/Streamlit-1.x-red.svg)](https://streamlit.io/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## What It Does

| Domain | Capability |
|---|---|
| **Codebase Q&A** | Ask questions about pipeline logic, SQL transformations, and design decisions — with cited sources |
| **Data Catalogue** | Discover tables, trace lineage, check PII sensitivity labels |
| **Pipeline Health** | Inspect run status, SLO adherence, recent failures |
| **Agentic Actions** | Trigger DQ checks, run What-If impact analysis, search PII tables |
| **Schema Drift** | Proactive sidebar alerts when source table schemas change |
| **Graph RAG** | 1-hop lineage-neighbour catalogue chunks automatically appended for lineage queries |
| **Live Agent Trace** | Every decision streamed live and persisted as a collapsible trace panel |

**Core Innovation — What-If Impact Engine:** before any column rename or table drop, the agent traces full lineage and surfaces every affected downstream asset — dashboards, marts, ML features — before code is merged.

---

## Architecture

```
┌─────────────────────────────────────────────┐
│           Streamlit UI  (port 8501)          │
│  Chat · Health Dashboard · Lineage DAG       │
└──────────────────────┬──────────────────────┘
                       │ HTTP + SSE
┌──────────────────────▼──────────────────────┐
│        FastAPI Backend  (port 8000)          │
│  Intent Router · RAG Engine · Agent Loop     │
│  MCP Server (stdio) · PII Guard · Metrics    │
└──────┬───────────────────────────┬───────────┘
       │                           │
┌──────▼──────┐           ┌────────▼────────┐     ┌─────────────────┐
│  ChromaDB   │           │    DuckDB        │     │   Groq Cloud    │
│  HNSW 768d  │           │  8 tables        │     │  8b  ·  70b     │
│  + BM25     │           │  lineage · runs  │     │  llama-3.x      │
└─────────────┘           └─────────────────┘     └─────────────────┘
```

### RAG Pipeline

```
Query
  → Intent Classification  (regex fast-path → 8b LLM fallback)
  → HyDE                   (hypothetical document generation)
  → Dense Retrieval        (ChromaDB HNSW)
  → Sparse Retrieval       (BM25Okapi)
  → RRF Fusion             (score = Σ 1/(k + rank), k=60)
  → Cross-encoder Rerank   (ms-marco-MiniLM-L-6-v2, sigmoid-normalised)
  → Graph Augmentation     (1-hop lineage neighbours — CATALOGUE/ACTION only)
  → Context Builder        (token budget · PII redaction · raw code injection)
  → Agent Loop             (Groq function-calling, intent-aware tool allowlist)
```

---

## Quick Start

### Prerequisites

- Python 3.11+
- A [Groq API key](https://console.groq.com) (free tier)
- Docker Desktop (optional, for containerised run)

### Local setup

```bash
# 1. Clone
git clone https://github.com/ManasShouche/pipelinemind.git
cd pipelinemind/pipelinemind

# 2. Create virtual environment
python3 -m venv .venv && source .venv/bin/activate

# 3. Install dependencies
pip install -e .

# 4. Configure environment
cp .env.example .env
# Edit .env — set GROQ_API_KEY=your_key_here

# 5. Seed the database
bash scripts/seed_db.sh

# 6. Ingest the pipeline corpus
bash scripts/ingest.sh        # full (LLM summaries)
# or
bash scripts/ingest_fast.sh   # fast (no LLM calls, fallback summaries)

# 7. Start API (Terminal 1)
bash scripts/start_api.sh
# → http://localhost:8000  |  docs: http://localhost:8000/docs

# 8. Start UI (Terminal 2)
bash scripts/start_ui.sh
# → http://localhost:8501
```

### Docker

```bash
cd pipelinemind
docker compose up --build
# API → http://localhost:8000
# UI  → http://localhost:8501
```

---

## MCP Tools

| Tool | Description | Requires Approval |
|---|---|---|
| `trigger_dq_check` | Run Great Expectations DQ suite on a table | **Yes** |
| `get_pipeline_status` | Fetch run status and history | No |
| `get_lineage_graph` | Upstream/downstream table lineage | No |
| `analyze_lineage_impact` | What-If blast radius before schema changes | No |
| `search_pii_tables` | List all PII-tagged tables and columns | No |
| `get_slo_report` | SLO adherence report for a pipeline | No |

---

## Test Questions

| Question | Intent | What to observe |
|---|---|---|
| *"Why does the orders pipeline use MERGE?"* | CODE_QA | Citations with file + relevance % |
| *"What PII is in dim_users?"* | CATALOGUE | PII column list + 🔒 warning |
| *"What is the lineage DAG for vw_revenue_by_tier?"* | CATALOGUE | Graph RAG chunks in Sources |
| *"What breaks if I drop user_id from stg_users?"* | ACTION | Impact analysis + risk score |
| *"Did the orders pipeline fail today?"* | HEALTH | Run history from DuckDB |
| *"Run a DQ check on stg_users"* | ACTION | Approval gate → Approve/Deny |

---

## Configuration

| Variable | Default | Description |
|---|---|---|
| `GROQ_API_KEY` | required | Groq Cloud API key |
| `GROQ_MODEL_FAST` | `llama-3.1-8b-instant` | SUMMARY · INTENT · HYDE calls |
| `GROQ_MODEL_AGENT` | `llama-3.3-70b-versatile` | Agent function-calling loop |
| `GROQ_API_KEY_SECONDARY` | optional | Second key for 429 round-robin |
| `MAX_CONTEXT_TOKENS` | `6000` | LLM context budget |
| `HYDE_ENABLED` | `true` | Toggle HyDE query expansion |
| `RERANK_ENABLED` | `true` | Toggle cross-encoder reranking |
| `API_BASE_URL` | `http://localhost:8000` | Override for Docker/cloud deployment |

---

## Project is inside `pipelinemind/`

All source code, scripts, tests, and docs live in the `pipelinemind/` subdirectory. See [`pipelinemind/README.md`](pipelinemind/README.md) for the full project structure and documentation index.
