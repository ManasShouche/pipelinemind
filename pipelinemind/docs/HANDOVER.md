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

```
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
```

---

## Key Data Flows

### Ingestion (one-time, then incremental)

```
Files → SHA-256 hash → skip unchanged → chunker → enricher → summary (Groq) →
embed (mpnet/CodeBERT) → ChromaDB.upsert (summary embedded, raw_code in metadata) →
BM25.add (corpus + chunk_ids) → pickle BM25 to disk
```

### Chat request

```
POST /api/v1/chat →
IntentClassifier (Groq 70b) →
HyDEProcessor (Groq 70b) →
ChromaRetriever (top-20) + BM25Retriever (top-20) →
RRF fusion (top-10) →
Reranker (top-5) →
ContextBuilder (token budget, PII redact, raw code inject) →
AgentLoop (Groq 70b function-calling, max 5 iter) →
SSE stream to Streamlit
```

### Tool approval flow

```
Agent selects trigger_dq_check →
AgentLoop returns approval_required SSE event →
Streamlit renders Allow/Deny buttons →
User clicks Allow →
POST /api/v1/chat/approve {approved: true} →
AgentLoop resumes with pending_approval →
tool executed, result returned
```

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
