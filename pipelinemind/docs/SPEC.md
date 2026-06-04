# PipelineMind — Specification

Version: 0.3 (in-flight)
Status: Demo-ready draft

---

## 1. Purpose

PipelineMind is a conversational AI assistant for Data Engineers. It
exposes three capabilities through a single chat surface:

1. **Codebase Q&A** over pipeline source files (Python, SQL, Airflow
   YAML, dbt manifests, Markdown docs).
2. **Catalogue exploration** — table schemas, column lineage,
   PII tagging.
3. **Pipeline health** — current state, recent failures, SLO adherence.

The system also provides **agentic actions** — model-initiated tool
calls (e.g. trigger a data-quality check) gated by a human-in-the-loop
approval step.

---

## 2. Scope

### 2.1 In scope

- A FastAPI backend that serves a `POST /api/v1/chat` SSE endpoint
  plus 13 supporting REST endpoints.
- A Streamlit multi-page UI: Chat / Health / Catalogue.
- A hybrid RAG pipeline:
  HyDE → dense (Chroma) + sparse (BM25) → RRF → cross-encoder rerank.
- A function-calling agent over 6 typed tools, exposed in-process to
  FastAPI and over an MCP `stdio` transport.
- Synthetic fixtures (5 Python ETL pipelines, 3 SQL files, 3 Airflow
  DAGs, dbt manifest+catalog, 30-day run logs, PII registry) for the
  demo dataset.

### 2.2 Out of scope (for this milestone)

- Multi-tenant auth.
- Production data persistence beyond DuckDB on disk.
- Real source ingestion from live data warehouses (Snowflake /
  BigQuery connectors are stubs).
- Streaming partial tool-call deltas from the LLM (Groq does not
  emit them mid-call).

---

## 3. Functional requirements

| ID    | Requirement                                                                                            |
|-------|--------------------------------------------------------------------------------------------------------|
| F-01  | The system shall accept natural-language questions through a chat UI and stream a response.            |
| F-02  | The system shall classify each query into exactly one of 5 intents (CODE_QA, CATALOGUE, HEALTH, ACTION, GENERAL). |
| F-03  | The system shall retrieve relevant chunks via hybrid RAG when the intent is not GENERAL.               |
| F-04  | The system shall surface inline citations with source file, chunk type, function name, and git hash.   |
| F-05  | The system shall call MCP-defined tools when the intent and the question warrant it.                   |
| F-06  | The system shall block any state-altering tool behind a human approval gate before execution.          |
| F-07  | The system shall expose a live "agent trace" view of each decision (intent, retrieval, tool calls).    |
| F-08  | The system shall expose a schema-drift sidebar banner driven by an MCP Resource.                       |
| F-09  | The system shall persist a 30-day pipeline-run history in DuckDB and answer health queries from it.    |
| F-10  | The system shall redact PII patterns from retrieved context before passing them to the LLM.            |
| F-11  | The system shall log every chat request with a request ID, latency, and status code.                   |
| F-12  | The system shall expose Prometheus metrics at `GET /metrics`.                                          |

---

## 4. Non-functional requirements

| ID    | Requirement                                                                                            |
|-------|--------------------------------------------------------------------------------------------------------|
| N-01  | First token of a chat response shall arrive within 2 s p50 on the demo dataset, 5 s p95.               |
| N-02  | End-to-end chat latency shall be ≤ 6 s p50, ≤ 10 s p95 (excluding cold-start cross-encoder load).      |
| N-03  | The agent shall not perform more tool calls than `INTENT_MAX_ITERATIONS[intent]` allows.               |
| N-04  | The system shall not crash when DuckDB is missing — it shall return a `db_not_seeded` marker.          |
| N-05  | The system shall not include irrelevant citations (sigmoid score < 0.10) in the user-visible expander. |
| N-06  | LLM cost — ≥ 60% of model calls (by count) shall be served by the cheap tier (`llama3-8b-8192`).       |
| N-07  | Every tool input shall be validated against a Pydantic v2 model before execution.                      |
| N-08  | Configuration shall be read from `.env` only; no secrets shall appear in source.                       |
| N-09  | The system shall recover from a single Groq `RateLimitError` via secondary key or exponential backoff. |
| N-10  | All filesystem writes shall stay inside the `pipelinemind/data/` and `pipelinemind/logs/` directories. |

---

## 5. External interfaces

### 5.1 REST API (FastAPI, prefix `/api/v1`)

| Method | Path                       | Purpose                                                |
|--------|----------------------------|--------------------------------------------------------|
| POST   | `/chat`                    | Streaming chat (SSE)                                   |
| POST   | `/chat/approve`            | Approve/deny a paused tool call                        |
| GET    | `/pipelines`               | List pipelines + latest status                         |
| GET    | `/pipelines/{id}/status`   | Detailed status for one pipeline                       |
| GET    | `/pipelines/{id}/slo`      | SLO report                                             |
| GET    | `/catalogue/tables`        | List catalogue tables (+ filters)                      |
| GET    | `/catalogue/tables/{name}` | Single-table detail (columns + PII flags)              |
| GET    | `/catalogue/lineage/{name}`| Lineage graph                                          |
| POST   | `/dq/trigger`              | Trigger DQ (REST equivalent of the MCP tool)           |
| GET    | `/dq/results`              | Latest DQ results                                      |
| POST   | `/impact/analyze`          | What-If schema impact                                  |
| GET    | `/schema-drift`            | Current drift events                                   |
| GET    | `/health`                  | Liveness                                               |
| GET    | `/agent/stats`             | LLM router call counts + rate-limit hits               |
| GET    | `/metrics`                 | Prometheus metrics (no `/api/v1` prefix)               |

### 5.2 SSE event types

See `INTERNALS.md` §3. Summary:

- `trace` — agent + retrieval decision events (live)
- `retrieval_complete` — citations + intent payload (for UI back-compat)
- `token` — partial answer text
- `done` — final response, tool calls, iterations, latency
- `approval_required` — paused tool call

### 5.3 MCP server (`stdio` transport)

- **Tools (6):** `trigger_dq_check` (approval-gated),
  `get_pipeline_status`, `get_lineage_graph`, `analyze_lineage_impact`,
  `search_pii_tables`, `get_slo_report`.
- **Resource:** `pipelinemind://schema-drift/latest` — JSON list of
  drift events (added/dropped/type-changed columns). Polled every
  300 s.
- **Prompt:** `diagnose_pipeline {pipeline_id}` — slash command that
  expands into a structured diagnostic prompt for the agent.

### 5.4 External services

- **Groq Cloud** (`api.groq.com`) — chat completions for all LLM
  calls. Key: `GROQ_API_KEY` (mandatory), `GROQ_API_KEY_SECONDARY`
  (optional, for round-robin on 429).

No other external services are contacted at runtime.

---

## 6. Data model (DuckDB)

```
pipelines            (pipeline_id PK, name, owner, schedule, …)
pipeline_runs        (run_id PK, pipeline_id FK, status, run_start, run_end, error_msg, …)
slo_thresholds       (pipeline_id PK, target_success_pct, target_latency_seconds)
catalogue_tables     (table_id PK, table_name, domain, owner, description)
catalogue_columns    (column_id PK, table_id FK, column_name, data_type, pii_flag, sensitivity_level)
lineage_edges        (src_table, dst_table, transformation_type)
dq_results           (result_id PK, table_name, suite_name, run_at, passed, failure_count, details_json)
schema_snapshots     (table_name PK, columns_json, captured_at)
```

All FK references are logical, not enforced (DuckDB 1.x semantics +
demo simplicity).

---

## 7. RAG pipeline contract

### 7.1 Intent classification

- Input: `query: str`.
- Output: `(Intent, confidence: float)`.
- Stage 1: regex keyword fast-path. Confidence ≥ 0.88.
- Stage 2 (only on miss): llama3-8b structured JSON, temp 0.0,
  60-token cap. Falls back to `(CODE_QA, 0.5)` on any error.

### 7.2 Retrieval

- `GENERAL` intent → skip retrieval entirely, return an empty
  `BuiltContext` with `confidence_score=1.0`.
- All other intents:
  1. HyDE expansion (if `HYDE_ENABLED=true`).
  2. Dense retrieval — Chroma HNSW, `top_k=top_k_dense`.
  3. Sparse retrieval — BM25Okapi, `top_k=top_k_sparse`.
  4. RRF fusion — `score = Σ 1/(k + rank)` with `k=rrf_k=60`,
     top `top_k_fused`.
  5. Cross-encoder rerank (sigmoid-normalised), top `top_k_rerank`.
  6. **Graph augmentation** (`CATALOGUE` / `ACTION` intents only) —
     extract table-name entities from top chunks, walk 1 hop in
     `lineage_edges`, append ≤ 3 catalogue-derived chunks
     (`score=0.55`, `retrieval_method="graph"`). No-op when DuckDB
     is absent or no entities are found.

### 7.3 Context building

- Filter chunks with score `< MIN_USEFUL_SCORE` (= 0.10); always keep
  one fallback chunk.
- Body selection: `raw_implementation` for `python`/`sql` chunks
  with non-empty raw, else the summary `document`.
- PII redaction over chunks with `pii_flag=True` — replace values of
  `email|phone|birth|ssn|password|secret|token` with `[REDACTED]`.
- Token budget: ≤ `MAX_CONTEXT_TOKENS × APPROX_CHARS_PER_TOKEN`
  characters (4 chars ≈ 1 token).
- `confidence_score` = top-chunk sigmoid score (clipped to `[0, 1]`).
- `low_confidence` if `confidence_score < CONFIDENCE_THRESHOLD`.

### 7.4 Citation payload

Each citation is a dict:

```
{
  "source_index":    int,        # 1-based, matches "[SOURCE n]" header
  "file":            str,
  "chunk_type":      str,
  "function_name":   str | None,
  "git_commit_hash": str | None,
  "score":           float       # sigmoid-normalised [0, 1]
}
```

Citations with `score < MIN_DISPLAY_SCORE` are hidden by the UI.

---

## 8. Agent contract

### 8.1 Tool registry

Six (name → Pydantic-model, callable) pairs in `TOOL_REGISTRY`. Adding
a tool requires three steps:

1. Define the validator in `agent/tools/validators.py`.
2. Implement the function in the appropriate `agent/tools/*_tools.py`.
3. Register both in `TOOL_REGISTRY` *and* in `_ALL_TOOL_DEFS` (Groq
   format) *and* in `INTENT_TOOL_ALLOWLIST` per intent.

### 8.2 Intent → tool allowlist

| Intent     | Tools                                                       |
|------------|-------------------------------------------------------------|
| CODE_QA    | (none — pure RAG)                                           |
| CATALOGUE  | `get_lineage_graph`, `search_pii_tables`                    |
| HEALTH     | `get_pipeline_status`, `get_slo_report`                     |
| ACTION     | all 6                                                       |
| GENERAL    | (none — direct generation)                                  |
| `None`     | all 6 (fallback when intent classification fails)           |

### 8.3 Iteration budgets

| Intent     | Max iterations |
|------------|----------------|
| CODE_QA    | 0              |
| CATALOGUE  | 1              |
| HEALTH     | 2              |
| ACTION     | 5              |
| GENERAL    | 0              |
| `None`     | 3              |

When the budget is exhausted, the agent makes one final synthesis
call with `tools=None` and returns whatever the model produces.

### 8.4 Approval gate

The set `APPROVAL_REQUIRED_TOOLS = {"trigger_dq_check"}` defines
state-altering tools. When the agent emits one of these:

1. The loop returns immediately with
   `requires_approval=True`, `approval_tool`, `approval_args`.
2. The UI renders the approval gate.
3. On approval, `POST /api/v1/chat/approve` is called; the agent
   re-runs with `pending_approval={…}` and the tool executes once.
4. On denial, the gate posts `{"status": "denied"}` and no tool runs.

### 8.5 Trace contract

`run(... , trace_callback=fn)` is best-effort: callback failures are
caught and logged; they never break the loop. See `INTERNALS.md` §3
for the event schema.

---

## 9. Cost & rate-limit policy

- `CallType.SUMMARY|INTENT|HYDE` route to `GROQ_MODEL_FAST`
  (default `llama-3.1-8b-instant`).
- `CallType.AGENT` routes to `GROQ_MODEL_AGENT`
  (default `llama-3.3-70b-versatile`).
- Per-call max tokens cap latency and cost: 200 / 60 / 250 / 2048.
- On `RateLimitError`:
  1. If `GROQ_API_KEY_SECONDARY` is set, retry once on the secondary
     key.
  2. Otherwise, tenacity in the caller does exponential backoff
     (`multiplier=1, min=2, max=30`, `stop_after_attempt(4)`).
- `LLMRouter.stats()` exposes `call_counts` and `rate_limit_hits`
  for observability.

---

## 10. Security & privacy

- No PII is sent to any external LLM verbatim. Chunks tagged with
  `pii_flag=True` pass through `_redact_pii()` before reaching the
  prompt.
- The `X-PII-Detected` response header is set when a PII-sensitive
  context is used; the UI consumes it as a soft signal.
- All state-altering tools are approval-gated (§ 8.4).
- The `mcp_server.py` stdio transport runs only when explicitly
  invoked (`python -m agent.mcp_server`); FastAPI does not launch it.
- `.env` is gitignored. `pyproject.toml` ships no secrets.

---

## 11. Acceptance criteria for v0.3

| #   | Criterion                                                                                       |
|-----|-------------------------------------------------------------------------------------------------|
| AC-1| `bash scripts/start_api.sh` boots and `GET /api/v1/health` returns 200 within 5 s.              |
| AC-2| `bash scripts/start_ui.sh` opens the Chat page; sidebar shortcuts are visible.                  |
| AC-3| Asking "What PII is in dim_users?" returns CATALOGUE intent + at least one cited source.        |
| AC-4| Asking "What happens if I drop user_id from stg_users?" returns ACTION intent + impact summary. |
| AC-5| Asking "Run a DQ check on stg_users" triggers the approval gate; denial does not run the tool.  |
| AC-6| The chat panel shows a live "🧠 Agent thinking…" trace updating as the response streams.       |
| AC-7| The persistent "🧠 Agent trace (N steps)" expander appears under each completed assistant turn.|
| AC-8| `GET /api/v1/agent/stats` confirms ≥ 60% of calls were served by `llama3-8b-8192`.              |
| AC-9| Running `pytest tests/unit/` produces a green run (no failed assertions).                       |
| AC-10| Docker `docker compose up --build` brings both services online.                                |

---

## 12. Open questions / future work

- **LLM backend swap (Claude / Azure OpenAI).** The brief requires
  Claude or Azure OpenAI; current implementation uses Groq. Planned
  for v0.4 — abstract `LLMRouter._call_with_fallback` behind a
  provider interface so the swap is a single-file change.
- **LangChain facade.** The brief lists LangChain. A thin
  `BaseRetriever` wrapper around `HybridRetriever` would close the
  gap without touching internals.
- **Self-reflection loop.** When `confidence_score < 0.5`, re-query
  with a broadened `top_k` or a paraphrased question before the
  agent runs.
- **Persistent conversations.** Move `st.session_state.messages`
  into a `conversations` DuckDB table so refresh doesn't drop
  history.
- **Cost/latency badge.** Render `{tokens, $, ms, n_tool_calls}` chip
  below each answer.
- **Qdrant alternative.** Add a `VECTOR_BACKEND` env switch and a
  `qdrant_retriever.py` parallel implementation.
