# PipelineMind — Internals

This document explains *how* PipelineMind works end-to-end. It is
intended for engineers extending the system. Pair with `ARCHITECTURE.md`
(diagrams) and `API_REFERENCE.md` (endpoints).

---

## 1. Request lifecycle (chat)

```
User types a question in the Streamlit chat panel
        │
        ▼
ui/components/chat_panel.py::_stream_chat()
   POST /api/v1/chat  (httpx streaming client)
        │
        ▼
api/routers/chat.py::chat()
   1. parse ChatRequest (pydantic v2)
   2. HybridRetriever.retrieve(query)
   3. open SSE stream → _event_stream(...)
        │
        ▼
retrieval/hybrid_retriever.py::HybridRetriever.retrieve()
   ├── IntentClassifier.classify()       (Theme C: keyword + 8b)
   ├── HyDEProcessor.generate()           (8b — skipped if GENERAL)
   ├── ChromaRetriever.retrieve()         (dense, HNSW)
   ├── BM25Retriever.retrieve()           (sparse)
   ├── reciprocal_rank_fusion(...)
   ├── Reranker.rerank()                  (cross-encoder + sigmoid)
   └── ContextBuilder.build()             (token budget + PII redaction)
        │
        ▼
SSE events streamed back:
   trace (intent_classified)
   trace (hyde_generated)            ← only if HyDE rewrote the query
   trace (retrieval_complete)
   retrieval_complete (citations payload — kept for UI back-compat)
        │
        ▼
AgentLoop.run(intent=..., trace_callback=put_on_queue)
   runs in executor thread, emits trace events into a Queue
        │
        ▼
Main async task drains the Queue, yields each as SSE "trace"
   tokens streamed → "done" (or "approval_required")
```

Once the SSE stream closes, the Streamlit panel:
1. Empties the live "🧠 Agent thinking…" placeholder.
2. Persists the assistant message (with trace + citations + intent +
   confidence) into `st.session_state.messages`.
3. Calls `st.rerun()` so the persistent trace expander appears below
   the answer.

---

## 2. Module-by-module deep dive

### 2.1 `pm_config.py`

Single pydantic-settings `Settings` class loaded once via
`@lru_cache(maxsize=1)`. Named `pm_config` (not `config`) to avoid
clashing with the PyPI `config` package that some transitive deps
install.

Settings are case-insensitive; `.env` is the only file read. All
storage paths are typed as `pathlib.Path`. Knob defaults are tuned for
the demo dataset:

- `max_context_tokens = 6000` — wider context is wasted on this corpus
- `top_k_dense = top_k_sparse = 20`, `top_k_fused = 10`, `top_k_rerank = 5`
- `rrf_k = 60` (standard RRF damping constant)
- `confidence_threshold = 0.6` — below this the UI shows "low confidence"

### 2.2 `agent/llm_router.py`

The single chokepoint for all Groq calls.

`CallType` enum routes a request to:
- A model (`_MODEL_MAP`),
- A token budget (`_MAX_TOKENS`),
- A temperature (`_TEMPERATURE`).

`LLMRouter.complete(...)`:
1. Builds the kwargs (model, messages, max_tokens, temperature, tools).
2. Increments `_call_counts[call_type]`.
3. Calls `_call_with_fallback(kwargs)` which tries the primary key and,
   on `RateLimitError`, transparently retries with
   `GROQ_API_KEY_SECONDARY` if configured.
4. Lets tenacity in the caller handle the *final* retry/back-off
   (typically in `_call_groq` inside `AgentLoop`).

`LLMRouter.stats()` returns the call counts, rate-limit hits, and
model assignment dict. Surfaced at `GET /api/v1/agent/stats` for
operational visibility.

### 2.3 `agent/agent_loop.py`

Three orthogonal mechanisms work together to keep the agent
disciplined:

1. **Prompt-level discipline** — system prompt explicitly states
   "answer exactly what was asked", per-tool preconditions, and a
   "STOP AFTER ANSWERING" clause.

2. **Intent-aware tool filtering** (`INTENT_TOOL_ALLOWLIST`).
   The list of Groq function-call definitions passed in `tools=…` is
   filtered before each call. CODE_QA and GENERAL receive an empty
   list → the loop takes the `if not available_tools:` short-circuit
   and never enters the iteration phase.

3. **Per-intent iteration budget** (`INTENT_MAX_ITERATIONS`). Bounds
   the for-loop even if the model is otherwise inclined to chain calls.

The function-calling loop itself:

```python
for iteration in range(max_iters):
    response = self._call_groq(messages, tools=available_tools)
    msg = response.choices[0].message
    if not msg.tool_calls:        # model produced final answer
        return AgentResult(...)
    for tc in msg.tool_calls:
        if tc.function.name in APPROVAL_REQUIRED_TOOLS:
            return AgentResult(requires_approval=True, …)   # pause
        result = self._execute_tool(name, args)             # validated + invoked
        messages.append({"role": "tool", "content": json.dumps(result)})
# budget exhausted — force one final synthesis call with tools=None
```

`_execute_tool(name, args)` looks up `(PydanticModel, callable)` in
`TOOL_REGISTRY`, validates the args, and calls the function. Errors
become `{"error": str(exc)}` results that the model can read and
recover from on the next iteration.

**Hallucination guard** — when no tools are offered, the model may
still narrate `"[Calling get_pipeline_status]…"`. `_HALLUCINATION_PATTERNS`
detects this; `_strip_hallucination` removes the bracket markers and
"I will call …" sentences. If the cleaned text is shorter than
~80 chars the loop retries with an explicit "answer from context only"
instruction.

**Trace callback** (new in this iteration) — every decision point in
the loop calls `_trace(phase, **payload)`, which forwards the dict to
the caller-supplied `trace_callback`. The chat router uses this to
stream live updates to the UI.

### 2.4 `agent/tools/*`

Six pure-Python tools backed by DuckDB (`pm_config.duckdb_path`):

| Tool                    | Reads                                 | Writes |
|-------------------------|---------------------------------------|--------|
| `get_pipeline_status`   | `pipeline_runs`                       | —      |
| `get_slo_report`        | `pipeline_runs`, `slo_thresholds`     | —      |
| `get_lineage_graph`     | `lineage_edges`                       | —      |
| `analyze_lineage_impact`| `lineage_edges`, `catalogue_*`        | —      |
| `search_pii_tables`     | `catalogue_columns`                   | —      |
| `trigger_dq_check`      | `dq_results` (stub append)            | append |

`tools/validators.py` holds Pydantic v2 models with strict typing.
Tool outputs are JSON-serialisable dicts — see each module's docstring
for the schema.

### 2.5 `agent/mcp_server.py`

A standalone MCP server (`stdio_server` transport) registers the same
6 tools under the MCP `Tool` primitive plus:
- **Resource** — `pipelinemind://schema-drift/latest` polls
  `_detect_schema_drift()` every 5 minutes (compares
  `catalogue_columns` vs `schema_snapshots.columns_json`).
- **Prompt** — `diagnose_pipeline` slash command surfaced through the
  MCP Prompt primitive.

`_validate_and_call(model_cls, func, args)` mirrors the in-process
validator so MCP tool calls reuse the same Pydantic gate.

### 2.6 `retrieval/intent_classifier.py`

Two-stage classifier.

**Stage 1 — keyword fast-path.** `_KEYWORD_RULES` is a list of
(regex, `Intent`, confidence) tuples. Order matters — ACTION precedes
CATALOGUE because "if I drop … from … lineage" should resolve to
ACTION. `_keyword_classify(query)` returns the first match or `None`.

**Stage 2 — LLM classifier.** Fires only when stage 1 returns `None`.
Routed through `CallType.INTENT` (8b, temperature 0.0, 60-token cap).
The prompt contains a `DECISION RULE` that names the keyword signals
that *must* yield CATALOGUE, plus 10 few-shot examples.

The classifier returns `(Intent, confidence)`. On any failure it
falls back to `(Intent.CODE_QA, 0.5)` so the pipeline keeps running.

### 2.7 `retrieval/hyde.py`

Single `HyDEProcessor.generate(query)` method. Routed through
`CallType.HYDE` (8b, temperature 0.35, 250 tokens). Prompt asks for a
"realistic technical document excerpt" so the embedded text matches
the surface form of indexed chunks. On exception → fall back to the
original query (recall degrades but the pipeline still works).

### 2.8 `retrieval/chroma_retriever.py` & `bm25_retriever.py`

Standard implementations: Chroma uses HNSW with 768-d mpnet embeddings
for text chunks and CodeBERT for code chunks (see
`ingestion/embedders.py`). BM25 is `rank_bm25.BM25Okapi` over
whitespace-tokenised summaries, persisted as a pickle at
`pm_config.bm25_index_path`.

Both return `list[RetrievedChunk]` (see
`retrieval/chroma_retriever.py:RetrievedChunk`). The chunk dataclass
carries `score`, `rank`, `retrieval_method`, the summary `document`,
optional `raw_implementation`, and metadata (`source_file`,
`chunk_type`, `function_name`, `git_commit_hash`, `pii_flag`, …).

### 2.9 `retrieval/rrf_fusion.py`

Reciprocal Rank Fusion. For each chunk seen by either retriever:

```
score = Σ over retrievers  1 / (k + rank)        where k = settings.rrf_k
```

Returns chunks sorted by fused score, top `settings.top_k_fused`.

### 2.10 `retrieval/reranker.py`

Cross-encoder (`ms-marco-MiniLM-L-6-v2`) scores each `(query, chunk)`
pair. Raw logit → sigmoid → `[0, 1]`. Writes the normalised score
back onto `chunk.score`, sorts descending, returns top
`settings.top_k_rerank`.

`MIN_DISPLAY_SCORE = 0.10` is the contract: anything below is treated
as irrelevance and either dropped from context (in `ContextBuilder`)
or hidden from the citations expander (in `chat_panel.py`).

### 2.11 `retrieval/context_builder.py`

Assembles the final LLM context.

1. Filter chunks below `MIN_USEFUL_SCORE = 0.10`. Always keep at
   least one chunk so the agent has *something* to ground in.
2. For each surviving chunk: choose the body — `raw_implementation`
   for `python`/`sql` chunks, else the `summary` document.
3. Run `_redact_pii()` over PII-tagged chunks (`pii_flag=True`).
   Pattern matches `email|phone|birth|ssn|password|secret|token`
   followed by `:` or `=` and replaces the value with `[REDACTED]`.
4. Add a `[SOURCE n] file (chunk_type | function | git:hash)` header.
5. Enforce token budget (`max_context_tokens × 4` chars).
6. Compute `confidence_score = top_chunk.score` (already in `[0, 1]`).
   `low_confidence = confidence < settings.confidence_threshold`.

Returns a `BuiltContext` with the assembled text plus
`citations: list[dict]` for the UI.

### 2.12 `api/routers/chat.py`

The endpoint produces a Server-Sent-Events stream. Event types:

| Event                | Payload                                                      |
|----------------------|--------------------------------------------------------------|
| `trace`              | `{phase, ...}` — see §3 below                                |
| `retrieval_complete` | `{confidence_score, has_pii, citations, low_confidence, intent}` |
| `token`              | `{text}` — partial answer chunks                             |
| `done`               | `{full_response, tool_calls, iterations, latency_ms}`        |
| `approval_required`  | `{tool_name, tool_args, message, latency_ms}`                |

**Bridging the agent thread.** The agent is CPU- and IO-bound in
sync code; running it directly in an `async def` would block the
event loop. We launch it in `loop.run_in_executor(None, …)` and pass
in a `trace_callback` that calls `queue.Queue.put()`. The async
generator polls the queue with `get_nowait()` + `await
asyncio.sleep(0.02)` until either an event arrives or the
`Future` completes. A sentinel object posted via
`Future.add_done_callback` lets the drain loop exit deterministically.

### 2.13 `api/middleware/`

- `logging.py` — structlog JSON middleware, adds `request_id`,
  latency, status code on every response.
- `pii_guard.py` — response header (`X-PII-Detected`) when the chat
  body contains a PII marker; UI uses this only for telemetry.

### 2.14 `ui/components/chat_panel.py`

The chat panel is the main user surface. Responsibilities:

- Wraps `httpx.Client(...).stream(...)` and parses SSE.
- Routes incoming events: `token` → live placeholder, `trace` →
  live trace placeholder, `retrieval_complete` → stash for later
  citation rendering, `done`/`approval_required` → finalise.
- Persists each turn into `st.session_state.messages` so prior
  agent traces, citations, intent and confidence pills stay
  visible across `st.rerun()` cycles.
- Renders the trace inline via `_format_trace_line(evt)` — one
  bullet per phase with emoji + bold label + key payload fields.

The intent pill (`Intent: \`HEALTH\``), confidence pill (green/orange/
red), PII warning, and citations expander all read from the saved
`msg_record` dict.

---

## 3. Trace event schema

Each `trace` SSE event is a JSON object with a `phase` key plus
phase-specific fields. The Streamlit UI renders them via
`_format_trace_line()`; downstream consumers (e.g. an eval harness)
can ignore phases they don't care about.

| Phase                 | Fields                                                                                 |
|-----------------------|----------------------------------------------------------------------------------------|
| `intent_classified`   | `intent: str`, `confidence: float`                                                     |
| `hyde_generated`      | `hyde_chars: int`, `hyde_preview: str`                                                 |
| `retrieval_complete`  | `chunks_retrieved`, `chunks_used`, `top_score`, `low_confidence`, `has_pii`            |
| `agent_start`         | `intent`, `tools_available: list[str]`, `max_iterations`, `has_context`, `context_chars`|
| `direct_generation`   | `reason: str`                                                                          |
| `iteration_start`     | `iteration`, `max_iterations`                                                          |
| `tool_start`          | `tool: str`, `args: dict`, `iteration` *(or `approved: bool`)*                         |
| `tool_end`            | `tool`, `duration_ms`, `result_preview`, `had_error: bool`                             |
| `approval_required`   | `tool`, `args`                                                                         |
| `hallucination_guard` | `action: "stripped"`                                                                   |
| `synthesis_forced`    | `reason: str`, `max_iterations`                                                        |
| `agent_done`          | `iterations`, `response_chars`, plus one of `llm_call_ms`/`synthesis_ms`/`duration_ms` |
| `error`               | `phase_failed`, `error`                                                                |

Retrieval-phase events (the first three) are synthesised *after*
`HybridRetriever.retrieve()` returns, since retrieval runs
synchronously. Agent-phase events are emitted live from inside the
worker thread.

---

## 4. Ingestion pipeline

`ingestion/ingest_pipeline.py` orchestrates:

1. **Discover** files under `--repo-path`, `--sql-path`, `--yaml-path`,
   `--dbt-path`.
2. **Chunk** each file with the type-appropriate chunker:
   - `ast_chunker.py` — tree-sitter Python; produces function / method
     / class / module chunks with line ranges + docstring.
   - `sql_chunker.py` — splits on semicolons + statement classifier.
   - `yaml_chunker.py` — Airflow DAG / task blocks.
   - `semantic_chunker.py` — Markdown headers + dbt manifest model
     nodes.
3. **Enrich** with `metadata_enricher.py`: PII flag from a regex over
   identifier + column name lists; git commit hash from `git log -n1`.
4. **Summarise** with `SummaryGenerator.batch_generate()` (or skip via
   `--skip-summaries` for fast ingestion).
5. **Embed** with the dual embedder in `embedders.py`
   (mpnet for text, CodeBERT for code chunks).
6. **Index** into ChromaDB (HNSW) and rebuild the BM25 pickle index.

`watcher.py` runs `watchdog.observers.Observer` against the
`pipeline_repo_path` and re-ingests changed files incrementally
(off by default — wired up for the demo).

---

## 5. DuckDB schema

See `db/schema.sql`. Six tables:

| Table                | Purpose                                       |
|----------------------|-----------------------------------------------|
| `pipelines`          | Pipeline registry + owners                    |
| `pipeline_runs`      | 30-day synthetic run history                  |
| `slo_thresholds`     | Per-pipeline SLO targets (success %, latency) |
| `catalogue_tables`   | Table-level catalogue rows                    |
| `catalogue_columns`  | Column-level rows incl. PII tag               |
| `lineage_edges`      | Directed edges between tables                 |
| `dq_results`         | Append-log of DQ check results                |
| `schema_snapshots`   | Baseline `columns_json` per table for drift   |

`db/seeder.py` loads JSON fixtures from `data/catalogue/`, shifts
`pipeline_runs.run_start` so the most-recent fixture is "now", and
inserts everything in one transaction.

---

## 6. Observability

- **structlog JSON logs** — `api/middleware/logging.py` wraps every
  request. Look for `request_id` to trace a chat through retrieval
  + agent.
- **Prometheus** — `GET /metrics`. The `pipelinemind_requests_total`
  counter and `pipelinemind_request_latency_seconds` histogram are
  registered in `api/main.py`. Easily scraped by any Prometheus stack.
- **Agent stats** — `GET /api/v1/agent/stats` shows the
  call-distribution across model tiers — useful to verify the cost
  story ("most calls land on 8b, only AGENT uses 70b").

---

## 7. Testing

- `tests/unit/` — chunkers, RRF fusion, validators, context builder,
  intent keyword classifier, agent intent routing.
- `tests/integration/` — each of the 6 MCP tools is exercised against
  the seeded DuckDB.
- `tests/eval/` — RAG evaluation harness producing MRR@5 and NDCG@5
  against a labelled question set. Run via
  `pytest tests/eval/ -v --tb=short`.

`conftest.py` at the project root inserts `.` at the front of
`sys.path` so the layered package layout resolves when running
pytest from the project root.
