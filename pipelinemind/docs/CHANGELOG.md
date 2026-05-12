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
