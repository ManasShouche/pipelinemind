# PipelineMind — Technical Specification

Version: 0.3
Audience: Engineers extending, deploying, or debugging the system.
Pair with `FUNCTIONAL_SPEC.md` for the *what* and *why*.

---

## 1. System overview

PipelineMind is a three-tier system:

```
┌──────────────────────────────┐
│   Streamlit UI (port 8501)   │
│   Chat / Health / Catalogue  │
└──────────────┬───────────────┘
               │ HTTP + SSE
┌──────────────▼───────────────┐
│   FastAPI backend (8000)     │
│   /api/v1/* routers          │
│   Hybrid RAG · Agent loop    │
│   MCP server (stdio, sep.)   │
└──────┬────────────┬──────────┘
       │            │
┌──────▼──────┐  ┌──▼─────────┐    ┌──────────────────┐
│  ChromaDB   │  │  DuckDB    │    │   Groq Cloud     │
│  HNSW + BM25│  │  8 tables  │    │   8b · 70b · 3.3 │
└─────────────┘  └────────────┘    └──────────────────┘
```

- **Process model.** The FastAPI app is a single uvicorn process.
  The MCP server is a separate, on-demand process (`python -m
  agent.mcp_server`) using stdio transport — not started by uvicorn.
- **Data plane.** ChromaDB persistent client (HNSW index, 768-d
  embeddings) + a pickle BM25 index. DuckDB holds operational
  metadata (pipelines, runs, catalogue, lineage, DQ results, schema
  snapshots).
- **LLM plane.** All Groq calls go through `LLMRouter`, which routes
  by `CallType` to the cheap (8b) or capable (70b/3.3) tier.

---

## 2. Component breakdown

### 2.1 `pm_config.py`

`pydantic-settings` `Settings` class, cached behind
`@lru_cache(maxsize=1)`. Reads `.env` only. Holds Groq keys, storage
paths, RAG knobs, agent budget.

### 2.2 `ingestion/`

Offline pipeline that produces the searchable index.

- `chunkers/ast_chunker.py` — tree-sitter Python; emits function /
  method / class / module chunks with line ranges and docstrings.
- `chunkers/sql_chunker.py` — splits SQL by `;`, classifies the
  statement type.
- `chunkers/yaml_chunker.py` — Airflow DAG and task blocks.
- `chunkers/semantic_chunker.py` — Markdown headers and dbt
  manifest model nodes.
- `metadata_enricher.py` — PII flag, git commit hash.
- `summary_generator.py` — `LLMRouter.complete(CallType.SUMMARY, …)`;
  produces 80–150-word natural-language summaries. Embeds the summary,
  not the raw code (the "embed-summary / retrieve-full" pattern).
- `embedders.py` — dual embedder: `all-mpnet-base-v2` for text,
  `microsoft/codebert-base` for code chunks.
- `ingest_pipeline.py` — orchestrator. Flags: `--repo-path`,
  `--sql-path`, `--yaml-path`, `--dbt-path`, `--skip-summaries`,
  `--force-reindex`.

### 2.3 `retrieval/`

Online RAG pipeline orchestrated by `hybrid_retriever.py`.

| Stage | Module                | Output                                                                      |
|-------|-----------------------|-----------------------------------------------------------------------------|
| 1     | `intent_classifier.py`| `(Intent, confidence)`. Stage 1 regex fast-path, stage 2 8b LLM.           |
| 2     | `hyde.py`             | Hypothetical document for embedding (skipped if GENERAL).                   |
| 3     | `chroma_retriever.py` | `top_k_dense` chunks (HNSW).                                                |
| 4     | `bm25_retriever.py`   | `top_k_sparse` chunks (BM25Okapi).                                          |
| 5     | `rrf_fusion.py`       | `top_k_fused` fused by `score = Σ 1/(k+rank)`.                              |
| 6     | `reranker.py`         | `top_k_rerank` re-ranked, sigmoid-normalised to [0,1].                      |
| 7     | `graph_augmentor.py`  | Appends ≤3 1-hop lineage-neighbour catalogue chunks. CATALOGUE/ACTION only. |
| 8     | `context_builder.py`  | `BuiltContext` (assembled text + citations).                                 |

### 2.4 `agent/`

| Module               | Responsibility                                                       |
|----------------------|----------------------------------------------------------------------|
| `llm_router.py`      | Single Groq chokepoint. Routes by `CallType`. Key rotation on 429.   |
| `agent_loop.py`      | Function-calling loop. Intent-aware tool filter + iteration budget. |
| `mcp_server.py`      | Standalone MCP server, stdio transport.                              |
| `mcp_resources.py`   | Schema drift polling logic (used by the resource and the API).       |
| `tools/validators.py`| Pydantic v2 input models for every tool.                             |
| `tools/*_tools.py`   | Five tool implementations, each pure-Python over DuckDB.             |

### 2.5 `api/`

| Module                       | Responsibility                                          |
|------------------------------|---------------------------------------------------------|
| `main.py`                    | App entry, middleware registration, Prometheus.         |
| `middleware/logging.py`      | structlog JSON middleware with request_id propagation. |
| `middleware/pii_guard.py`    | `X-PII-Detected` response header.                       |
| `models/__init__.py`         | Request/response models.                                |
| `routers/chat.py`            | `/chat` SSE + `/chat/approve` approval gate.            |
| `routers/pipelines.py`       | Pipeline status + SLO read endpoints.                   |
| `routers/catalogue.py`       | Catalogue + lineage read endpoints.                     |
| `routers/dq.py`              | DQ trigger + result endpoints.                          |
| `routers/impact.py`          | What-If impact endpoint.                                |

### 2.6 `ui/`

Streamlit multi-page app.

| Module                                  | Responsibility                                |
|-----------------------------------------|-----------------------------------------------|
| `app.py`                                | Entry point, sidebar, page registration.      |
| `pages/01_Chat.py`                      | Imports `chat_panel.render_chat_panel`.       |
| `pages/02_Health.py`                    | Imports the health dashboard component.       |
| `pages/03_Catalogue.py`                 | Imports the lineage graph component.          |
| `components/chat_panel.py`              | Streaming chat + trace + citations + PII.     |
| `components/approval_gate.py`           | Approve / Deny gate for state-altering tools. |
| `components/health_dashboard.py`        | Pipeline status table.                        |
| `components/lineage_graph.py`           | `streamlit-agraph` DAG renderer.              |
| `components/schema_drift_banner.py`     | Sidebar banner.                               |

---

## 3. Data model (DuckDB)

```
pipelines           (pipeline_id PK, name, owner, schedule, …)
pipeline_runs       (run_id PK, pipeline_id FK, status, run_start, run_end, error_msg)
slo_thresholds      (pipeline_id PK, target_success_pct, target_latency_seconds)
catalogue_tables    (table_id PK, table_name, domain, owner, description)
catalogue_columns   (column_id PK, table_id FK, column_name, data_type, pii_flag, sensitivity_level)
lineage_edges       (src_table, dst_table, transformation_type)
dq_results          (result_id PK, table_name, suite_name, run_at, passed, failure_count, details_json)
schema_snapshots    (table_name PK, columns_json, captured_at)
```

- All foreign-key references are logical, not enforced — DuckDB 1.x
  semantics, and a deliberate choice for fixture flexibility.
- `db/seeder.py` shifts `pipeline_runs.run_start` so the most recent
  fixture row lands at `now`, ensuring "last 24 h" queries always find
  data regardless of fixture age.

---

## 4. External interfaces

### 4.1 REST API (prefix `/api/v1`)

| Method | Path                            | Purpose                                       |
|--------|---------------------------------|-----------------------------------------------|
| POST   | `/chat`                         | Streaming chat (SSE)                          |
| POST   | `/chat/approve`                 | Approve/deny a paused tool call               |
| GET    | `/pipelines`                    | List pipelines + latest status                |
| GET    | `/pipelines/{id}/status`        | Detailed status                               |
| GET    | `/pipelines/{id}/slo`           | SLO report                                    |
| GET    | `/catalogue/tables`             | List catalogue tables                         |
| GET    | `/catalogue/tables/{name}`      | Table detail + PII flags                      |
| GET    | `/catalogue/lineage/{name}`     | Lineage graph                                 |
| POST   | `/dq/trigger`                   | REST equivalent of the MCP DQ tool            |
| GET    | `/dq/results`                   | Latest DQ results                             |
| POST   | `/impact/analyze`               | What-If impact analysis                       |
| GET    | `/schema-drift`                 | Current drift events                          |
| GET    | `/health`                       | Liveness                                      |
| GET    | `/agent/stats`                  | LLM router call counts + rate-limit hits      |
| GET    | `/metrics` (no `/api/v1`)       | Prometheus metrics                            |

### 4.2 SSE event types

Emitted in this order by `/api/v1/chat`:

1. `trace` (`phase=intent_classified`) — synthesised from
   `RetrievalResult`.
2. `trace` (`phase=hyde_generated`) — only if HyDE rewrote the
   query.
3. `trace` (`phase=retrieval_complete`) — the trace variant.
4. `retrieval_complete` — the back-compat payload that carries
   citations to the UI.
5. *(zero or more)* `trace` (`phase=agent_start`,
   `iteration_start`, `tool_start`, `tool_end`, `synthesis_forced`,
   `hallucination_guard`, `agent_done`, `error`).
6. *(zero or more)* `token` — partial answer text.
7. `done` — final response, tool calls, iterations, latency.
8. *(or, instead of token+done)* `approval_required` — paused tool
   call with `tool_name`, `tool_args`, `message`, `latency_ms`.

Each event payload schema is documented in `docs/INTERNALS.md` §3.

### 4.3 MCP server (`stdio` transport)

Exposes the three MCP primitives:

- **Tools (6)** — `trigger_dq_check` is flagged
  `[REQUIRES_HUMAN_APPROVAL]` in its description; the in-process
  agent and the MCP host are both expected to honour the flag.
- **Resource (1)** — `pipelinemind://schema-drift/latest`. Polled
  every 300 s.
- **Prompt (1)** — `diagnose_pipeline {pipeline_id}` — slash command
  that expands into a structured diagnostic instruction sequence.

### 4.4 External services

- **Groq Cloud** (`api.groq.com`) — the only network dependency at
  runtime. Auth via `GROQ_API_KEY`; optional `GROQ_API_KEY_SECONDARY`
  for round-robin on `RateLimitError`.

---

## 5. Algorithms

### 5.1 Intent classification

**Stage 1 — keyword fast-path.** Ordered list of (compiled regex,
`Intent`, confidence) tuples. Returns the first match or `None`.
Confidence values: ACTION=0.95, CATALOGUE=0.95, HEALTH=0.93,
CODE_QA=0.92, GENERAL=0.88.

**Stage 2 — LLM classifier.** Fires only if Stage 1 returns `None`.
`CallType.INTENT` → 8b, temperature 0.0, 60-token cap. Prompt contains
a `DECISION RULE` block listing the keyword signals that *must* yield
CATALOGUE plus 10 few-shot examples. Output: `{"intent": ..., "confidence": ...}`.
On any error: fall back to `(CODE_QA, 0.5)`.

### 5.2 RRF fusion

For each chunk seen by either retriever, ranked at positions
`r_dense` and `r_sparse` (use `inf` if missing):

```
score = 1/(k + r_dense) + 1/(k + r_sparse)        where k = rrf_k = 60
```

Sort by fused score desc, return top `top_k_fused`.

### 5.3 Cross-encoder rerank

Score each `(query, chunk.document[:512])` pair with
`ms-marco-MiniLM-L-6-v2`. Apply sigmoid:

```
normalised = 1 / (1 + exp(-raw_logit))
```

Write back to `chunk.score`, sort desc, return top `top_k_rerank`.

### 5.4 Graph augmentation

Fires after stage 6 (reranker) for **CATALOGUE** and **ACTION** intents only.

1. Scan the top-3 reranked chunks for table-name-like tokens using the
   regex `(stg|dim|fct|vw|raw|…)_[a-z][a-z0-9_]{2,40}`.
2. If any found, query `lineage_edges` in DuckDB for 1-hop upstream
   and downstream neighbours of those tables.
3. For each neighbour (up to 3, sorted alphabetically), build a
   synthetic `RetrievedChunk` from `catalogue_tables` +
   `catalogue_columns` with:
   - `retrieval_method = "graph"`
   - `score = 0.55` (above `MIN_USEFUL_SCORE`; below typical top-RAG scores)
   - `chunk_type = "catalogue"`
4. Append the graph chunks to the ranked list; pass the combined list
   to the context builder.

The augmentor is a **no-op** when DuckDB is not seeded, when no table
entities are found, or when any exception is raised — it never breaks
the pipeline.

### 5.5 Context builder

1. Filter chunks with `score < MIN_USEFUL_SCORE` (= 0.10). If none
   survive, keep the top-1 regardless.
2. For each chunk: choose body — `raw_implementation` for
   `python`/`sql` chunks with non-empty raw, else the summary
   `document`.
3. PII redaction on chunks where `pii_flag=True`. Pattern matches
   `email|phone|birth|ssn|password|secret|token` followed by `:` or
   `=`; replaces the value with `[REDACTED]`.
4. Compose a header per chunk:
   `[SOURCE n] {file} ({chunk_type} | {function_name} | git:{hash})`.
5. Enforce token budget:
   `MAX_CONTEXT_TOKENS × APPROX_CHARS_PER_TOKEN` characters.
6. `confidence_score = top_chunk.score`; `low_confidence` if
   `confidence_score < CONFIDENCE_THRESHOLD`.

### 5.6 Agent loop

```python
def run(user_message, context_text, history, pending_approval, intent, trace_callback):
    messages = build_messages(SYSTEM_PROMPT, context_text, history, user_message)
    tools = INTENT_TOOL_ALLOWLIST[intent]
    max_iters = INTENT_MAX_ITERATIONS[intent]

    emit_trace("agent_start", ...)

    if not tools:
        result = llm(messages, tools=None)
        text = strip_hallucinations(result.text)
        emit_trace("agent_done", ...)
        return AgentResult(text, tool_calls=[], iterations=1, ...)

    if pending_approval:
        result = execute_tool(pending_approval.name, pending_approval.args)
        messages.append(tool_message(result))

    for iter in range(max_iters):
        emit_trace("iteration_start", iter)
        resp = llm(messages, tools=tools)
        if not resp.tool_calls:
            emit_trace("agent_done", ...)
            return AgentResult(resp.text, ...)
        for tc in resp.tool_calls:
            if tc.name in APPROVAL_REQUIRED_TOOLS:
                emit_trace("approval_required", tc.name)
                return AgentResult(requires_approval=True, ...)
            emit_trace("tool_start", tc.name, tc.args)
            result = execute_tool(tc.name, tc.args)
            emit_trace("tool_end", duration_ms=..., result_preview=...)
            messages.append(tool_message(result))

    # Budget exhausted — force final synthesis
    emit_trace("synthesis_forced", reason="intent_budget_exhausted")
    final = llm(messages + [{"role": "user", "content": "Synthesise now."}], tools=None)
    emit_trace("agent_done", budget_exhausted=True)
    return AgentResult(final.text, ...)
```

### 5.7 Trace-event bridge (FastAPI ↔ agent thread)

The agent is synchronous and CPU/IO-bound. It runs in
`asyncio.get_event_loop().run_in_executor(None, ...)`. A
`queue.Queue` shuttles trace events from the worker thread back to
the async generator:

1. Async generator creates `trace_q = queue.Queue()`.
2. Submits the agent task with `trace_callback = trace_q.put`.
3. Attaches `future.add_done_callback(lambda _: trace_q.put(_SENTINEL))`.
4. Drains: `get_nowait()` with `await asyncio.sleep(0.02)` between
   polls. Emits each event as an SSE `trace` frame.
5. Exits when the sentinel is read.
6. Awaits the future for the final `AgentResult`.

This pattern allows live streaming without GIL contention and without
blocking the event loop.

---

## 6. LLM routing strategy

| CallType | Model                      | Max tokens | Temperature | Justification                                |
|----------|----------------------------|------------|-------------|----------------------------------------------|
| SUMMARY  | `llama-3.1-8b-instant`     | 200        | 0.1         | Short summaries, high volume at ingestion.   |
| INTENT   | `llama-3.1-8b-instant`     | 60         | 0.0         | Deterministic 2-field JSON classification.   |
| HYDE     | `llama-3.1-8b-instant`     | 250        | 0.35        | Vocab bridging, no reasoning depth needed.    |
| AGENT    | `llama-3.3-70b-versatile`  | 2048       | 0.2         | Only call type that needs tool-calling.       |

Rationale: 60–70 % of LLM calls go to the cheap tier, leaving 70b
quota free for the agent loop. `LLMRouter.stats()` exposes the
counts for verification.

### 6.1 Rate-limit policy

1. On `RateLimitError` on the primary key, retry the same call on
   `GROQ_API_KEY_SECONDARY` if configured.
2. On a second 429 (or no secondary), the caller's tenacity decorator
   takes over: exponential backoff
   (`multiplier=1, min=2, max=30, stop_after_attempt(4)`).
3. After all retries, surface the error to the user and emit a
   `trace(phase=error, phase_failed="llm_call", error=str(exc))`.

---

## 7. Non-functional requirements

| ID    | Requirement                                                                                            |
|-------|--------------------------------------------------------------------------------------------------------|
| N-01  | First token latency ≤ 2 s p50, ≤ 5 s p95 on the demo dataset.                                          |
| N-02  | End-to-end chat latency ≤ 6 s p50, ≤ 10 s p95 (excluding cross-encoder cold start).                    |
| N-03  | The agent shall never exceed `INTENT_MAX_ITERATIONS[intent]` tool-call iterations.                     |
| N-04  | The system shall return a non-error `db_not_seeded` marker when DuckDB is absent.                      |
| N-05  | Citations below `MIN_DISPLAY_SCORE = 0.10` shall be hidden from the user.                              |
| N-06  | ≥ 60 % of LLM calls (by count) shall be served by the cheap tier (`llama-3.1-8b-instant`).             |
| N-07  | Every tool input shall be validated against a Pydantic v2 model before invocation.                     |
| N-08  | All configuration shall be read from `.env`; no secrets in source.                                     |
| N-09  | The system shall recover from a single Groq 429 via secondary key or exponential backoff.              |
| N-10  | Filesystem writes shall be confined to `pipelinemind/data/` and `pipelinemind/logs/`.                  |
| N-11  | The chat endpoint shall not block the event loop while the agent runs (executor pattern).              |
| N-12  | The trace-event bridge shall not lose events under normal operation (queue is unbounded; sentinel guards drain). |

---

## 8. Security and privacy

- No PII leaves the cluster verbatim. Chunks tagged `pii_flag=True`
  pass through `_redact_pii()` before reaching the LLM context.
- `X-PII-Detected` response header set when PII context is used.
- All state-altering tools (currently only `trigger_dq_check`) are
  approval-gated.
- The MCP stdio server is not bound to a port; it only runs when
  invoked explicitly.
- `.env` is gitignored. `pyproject.toml` ships zero secrets.
- The cross-encoder, embedders, and BM25 index run locally — no
  embeddings are sent off-host.

---

## 9. Deployment topology

### 9.1 Local development

```
Terminal 1: bash scripts/start_api.sh    # uvicorn :8000
Terminal 2: bash scripts/start_ui.sh     # streamlit :8501
```

`scripts/start_api.sh` auto-seeds DuckDB if the file is missing.
`scripts/ingest_fast.sh` builds the indexes (no LLM summaries).

### 9.2 Docker compose

Two services in `docker-compose.yml`:

| Service | Dockerfile        | Port |
|---------|-------------------|------|
| `api`   | `Dockerfile.api`  | 8000 |
| `ui`    | `Dockerfile.ui`   | 8501 |

Volumes mount `data/` and `logs/` from the host so indexes and
DuckDB persist across container restarts.

### 9.3 Production (out of scope for v0.3)

The system is engineered to run as two horizontally scalable replicas
behind a load balancer. ChromaDB would move to its server mode,
DuckDB would be replaced by a managed warehouse, and the LLM keys
would come from a secrets manager.

---

## 10. Observability

| Source             | What it gives you                                              |
|--------------------|----------------------------------------------------------------|
| structlog JSON logs| `request_id` propagated through retrieval + agent + tool calls |
| Prometheus         | `pipelinemind_requests_total`, `pipelinemind_request_latency_seconds` |
| Agent stats        | `GET /api/v1/agent/stats` — call counts per `CallType` + 429 hits |
| SSE trace events   | Per-request live decision trail; also persisted in UI session  |

---

## 11. Failure modes and recovery

| Failure                              | Behaviour                                                              |
|--------------------------------------|------------------------------------------------------------------------|
| Groq returns 429                     | Retry on secondary key → exponential backoff → user-visible error.     |
| Groq returns non-429 error           | Surface to user; emit `trace(error)`; conversation continues.          |
| Tool raises an exception             | Returned as `{"error": str(exc)}` to the model; loop continues.        |
| Tool input fails Pydantic validation | Returned as `{"error": "Validation failed", "self_correction_hint": …}` so the agent can retry with corrected args. |
| DuckDB file missing                  | `/schema-drift` returns `{db_not_seeded: true}`; auto-seed runs at API start. |
| ChromaDB index empty                 | `chunks_retrieved=0`; ContextBuilder returns "no relevant documents."  |
| HyDE call fails                      | Fall back to original query — recall degrades, correctness preserved.  |
| Intent classifier fails              | Fall back to `(CODE_QA, 0.5)`; agent uses the broad fallback toolset.   |
| Hallucinated tool call               | `_strip_hallucination` removes the fabricated text; retry if too short. |
| Iteration budget exhausted           | One forced synthesis call with `tools=None`; mark `budget_exhausted=True`. |
| Trace callback raises                | Logged at DEBUG, agent loop continues unaffected.                       |

---

## 12. Extension points

| To do this                  | Touch these files                                                                 |
|-----------------------------|------------------------------------------------------------------------------------|
| Add a new tool              | `agent/tools/validators.py`, `agent/tools/<group>_tools.py`, `TOOL_REGISTRY`, `_ALL_TOOL_DEFS`, `INTENT_TOOL_ALLOWLIST`, optionally `mcp_server.py`. |
| Add a new intent            | `retrieval/intent_classifier.py` (Stage 1 + Stage 2 few-shots), `INTENT_TOOL_ALLOWLIST`, `INTENT_MAX_ITERATIONS`. |
| Swap LLM provider           | `agent/llm_router.py` — replace `Groq` client with the new SDK; keep the `CallType` taxonomy. |
| Swap vector store           | Add `retrieval/<store>_retriever.py` mirroring `chroma_retriever.py`; switch in `hybrid_retriever.py`. |
| Tune graph augmentation     | Edit `retrieval/graph_augmentor.py`: adjust `_MAX_GRAPH_CHUNKS`, `_GRAPH_SCORE`, `_TABLE_RE`, or hop depth in `_get_neighbour_tables`. |
| Add a new chunker           | `ingestion/chunkers/<type>_chunker.py`; register in `ingest_pipeline.py`.         |
| Add a new SSE event type    | Emit from `api/routers/chat.py`; handle in `ui/components/chat_panel.py::_stream_chat`. |
| Add a new trace phase       | Call `_trace("phase", ...)` from `agent_loop.py`; format in `chat_panel.py::_PHASE_ICONS` and `_format_trace_line`. |
