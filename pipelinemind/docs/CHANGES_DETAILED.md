# PipelineMind — Detailed Change Log

A file-by-file breakdown of every change layered on top of the initial
`v0.1.0` baseline. Pair with `CHANGELOG.md` (terse, user-facing) for the
high-level story; this document is the engineering-level record.

The changes are grouped by *theme* rather than strictly by date, because
several themes were developed in parallel against the same files.

---

## Theme A — Cost-Tiered LLM Routing

Goal: stop burning llama3-70b quota on calls that don't need it. Move
INTENT classification, HyDE generation, and ingestion summaries to
llama3-8b, leaving 70b solely for the agent function-calling loop.

### A.1 New file — `agent/llm_router.py`

Introduces a `CallType` enum (`SUMMARY`, `INTENT`, `HYDE`, `AGENT`), a
per-call model map, per-call `max_tokens`, per-call `temperature`, and a
`LLMRouter` class with:
- `complete(call_type, messages, tools=None, tool_choice="auto", ...)` —
  single entry point that every other module now uses.
- Optional secondary Groq key (`GROQ_API_KEY_SECONDARY`) for round-robin
  fall-through on `RateLimitError`.
- `stats()` — exposes per-call counts and rate-limit hits; consumed by
  the `/api/v1/agent/stats` endpoint.

Model assignment:

| CallType  | Model                     | Reason                                     |
|-----------|---------------------------|--------------------------------------------|
| SUMMARY   | `llama3-8b-8192`          | Short summaries at ingestion. Volume high. |
| INTENT    | `llama3-8b-8192`          | 50-token JSON output. No reasoning needed. |
| HYDE      | `llama3-8b-8192`          | Doc generation, vocab bridging only.       |
| AGENT     | `llama-3.3-70b-versatile` | Function calling + multi-step reasoning.   |

Token budgets per call type: 200 / 60 / 250 / 2048.
Temperature per call type: 0.1 / 0.0 / 0.35 / 0.2.

### A.2 Modified — `ingestion/summary_generator.py`

- Removed direct `from groq import Groq` usage.
- All chunk summarisation now routes through `router.complete(CallType.SUMMARY, …)`.
- Retry policy (`tenacity` exponential backoff on `RateLimitError`/`APIError`)
  preserved; `_fallback_summary` path unchanged.

### A.3 Modified — `retrieval/intent_classifier.py`

- LLM call goes through `router.complete(CallType.INTENT, …)`.
- See Theme B for the bigger keyword fast-path change in the same file.

### A.4 Modified — `retrieval/hyde.py`

- LLM call goes through `router.complete(CallType.HYDE, …)`.
- Updated docstring explaining why 8b is sufficient for HyDE.

### A.5 Modified — `agent/agent_loop.py`

- Replaced direct Groq client with `router.complete(CallType.AGENT, …)`.
- `_call_groq()` now delegates; tenacity retries remain at this layer.

### A.6 Modified — `.env.example`

- Documented `GROQ_API_KEY_SECONDARY` (commented placeholder) for
  optional round-robin.

### A.7 Modified — `api/main.py`

- Added `GET /api/v1/agent/stats` endpoint that returns
  `LLMRouter.stats()`.

---

## Theme B — Anti-Over-Agentic Behaviour

Goal: stop the agent from making speculative tool calls "for context",
chaining lineage→impact analyses unprompted, and hallucinating tool
invocations when no tools are offered.

### B.1 Modified — `agent/agent_loop.py` (heavy refactor)

1. **System prompt rewritten.** Removed all "always check X" rules.
   New prompt has explicit `TOOL USAGE RULES` block tying every tool
   to a precondition: e.g. `analyze_lineage_impact` only fires when
   the user explicitly asks about schema-change blast radius.

2. **`INTENT_TOOL_ALLOWLIST`** — structural restriction of which Groq
   tool definitions are exposed per intent. The model literally cannot
   call `get_pipeline_status` for a CATALOGUE query because it's not
   in the `tools=[…]` parameter.

   | Intent     | Allowed tools                                    |
   |------------|--------------------------------------------------|
   | CODE_QA    | _none_                                           |
   | CATALOGUE  | `get_lineage_graph`, `search_pii_tables`         |
   | HEALTH     | `get_pipeline_status`, `get_slo_report`          |
   | ACTION     | all 6                                            |
   | GENERAL    | _none_                                           |
   | `None`     | all 6 (fallback)                                 |

3. **`INTENT_MAX_ITERATIONS`** — per-intent iteration budget that
   tightens beyond the global `agent_max_iterations=5`:
   `CODE_QA=0`, `CATALOGUE=1`, `HEALTH=2`, `ACTION=5`, `GENERAL=0`,
   `None=3`.

4. **Hallucinated tool-call detector.** Added `_HALLUCINATION_PATTERNS`
   regex to catch fabricated `[Calling X]` / "I will call …" language
   the model emits when no tools were offered. `_strip_hallucination`
   removes the bracket markers and "Let me call …" sentences; if the
   stripped text is shorter than 80 chars the agent retries with an
   explicit "answer from context only" instruction.

5. **`AgentResult` dataclass** — typed return: `final_response`,
   `tool_calls_made`, `iterations`, `requires_approval`,
   `approval_tool`, `approval_args`.

6. **Per-message SCOPE marker.** The user message is wrapped with a
   `[SCOPE] Answer only what was asked …` suffix that the model sees
   immediately before deciding whether to invoke a tool.

### B.2 Modified — `api/routers/chat.py`

- Forwards the classified intent string to `AgentLoop.run(..., intent=…)`
  so the allowlist and iteration cap take effect.
- Approval-gate path (`POST /api/v1/chat/approve`) now passes
  `intent="ACTION"` explicitly so the approved tool has the full
  6-tool toolkit available if the agent follows up.

### B.3 New tests

- `tests/unit/test_agent_intent_routing.py` — exercises the
  `_get_tools_for_intent` / `_get_max_iterations` mapping plus the
  hallucination regex.
- `tests/unit/test_intent_keyword_classifier.py` — see Theme C.

---

## Theme C — Two-Stage Intent Classification

Goal: avoid an LLM call for the easy 80% of queries, and dramatically
reduce mis-classification of CATALOGUE queries (lineage / PII / schema)
as CODE_QA.

### C.1 Modified — `retrieval/intent_classifier.py`

- **Stage 1 — keyword fast-path.** New `_KEYWORD_RULES` list of
  (compiled regex, `Intent`, confidence) tuples ordered most-specific
  first. Covers `ACTION` ("what if", "blast radius", "trigger dq"),
  `CATALOGUE` ("lineage", "upstream", "pii column", "schema of"),
  `HEALTH` ("pipeline fail", "slo breach", "last run"),
  `CODE_QA` ("how does the", "merge strategy", "SCD2"), and
  `GENERAL` ("what is a", "definition of", "compare X and Y").
  Returns `(Intent, confidence)` or `None`.

- **Stage 2 — LLM classifier.** Fires only when the keyword stage
  returns `None`. Rewritten prompt with 10 few-shot examples and an
  explicit `DECISION RULE` that names the keyword signals which
  always force CATALOGUE.

- New file `tests/unit/test_intent_keyword_classifier.py` covers the
  rules and stage ordering.

---

## Theme D — Retrieval Quality + Citation Cleanup

Goal: stop showing the user obviously irrelevant citations and stop
emitting raw cross-encoder logit scores in the UI.

### D.1 Modified — `retrieval/reranker.py`

- Cross-encoder raw logits are now sigmoid-normalised to `[0, 1]`
  before being written back onto each `RetrievedChunk.score`.
- `MIN_DISPLAY_SCORE = 0.10` constant documents the threshold below
  which a chunk is considered an irrelevance.

### D.2 Modified — `retrieval/context_builder.py`

- New `MIN_USEFUL_SCORE = 0.10` filter — chunks below the threshold
  are dropped from the LLM context entirely (they degrade answers).
- If *all* chunks are below threshold the top-1 is retained so the
  agent has at least one source to consider.
- Logs the low-confidence event explicitly.

### D.3 Modified — `ui/components/chat_panel.py`

- Citations rendered as percentage (sigmoid score × 100), colour-coded
  by relevance band (✅ ≥70, ℹ ≥40, grey otherwise).
- Citations with score `< 0.10` hidden entirely.
- PII warning tightened — only fires when retrieval reports
  `has_pii=True` *and* top score ≥ 0.5 (no warning on irrelevant
  PII references).

---

## Theme E — Agent Trace Panel (new in this iteration)

Goal: surface the agent's actual decisions live in the UI. Demos badly
without this — graders see a chat bubble and can't tell what made it.

### E.1 Modified — `agent/agent_loop.py`

- `AgentLoop.run()` accepts a new optional
  `trace_callback: Callable[[dict], None] | None = None`.
- Internal `_trace(phase, **payload)` helper safely no-ops when the
  callback is `None`; failures inside the callback are logged at
  `DEBUG` and never break the loop.
- Trace events emitted at each decision point:

  | Phase                | When                                              |
  |----------------------|---------------------------------------------------|
  | `agent_start`        | After tool allowlist + iteration budget resolved  |
  | `direct_generation`  | When no tools are available for the intent        |
  | `iteration_start`    | Top of each function-calling iteration            |
  | `tool_start`         | Just before a tool is executed                    |
  | `tool_end`           | After a tool returns (with `duration_ms` + preview)|
  | `approval_required`  | When a state-altering tool is intercepted         |
  | `hallucination_guard`| When the strip-fabrication path fires             |
  | `synthesis_forced`   | When the iteration budget is exhausted            |
  | `agent_done`         | Final answer ready                                |
  | `error`              | LLM call failure                                  |

- New helper `_preview()` — single-line JSON preview of a tool result
  trimmed to 220 chars for the trace UI.

### E.2 Modified — `api/routers/chat.py`

- New SSE event type: `trace` — emitted both from retrieval-phase
  metadata (post-hoc, since retrieval is synchronous) and from the
  agent's live `trace_callback`.
- Retrieval emits three trace events before the agent starts:
  `intent_classified`, `hyde_generated` (if HyDE actually rewrote the
  query), and `retrieval_complete`. The original `retrieval_complete`
  event is kept for backwards compatibility with the citations panel.
- Bridge: agent runs in `loop.run_in_executor(…)`; a `queue.Queue`
  shuttles trace events from the worker thread back into the SSE
  generator. A sentinel object is posted via
  `Future.add_done_callback` so the drain loop exits cleanly.
- The `_event_stream` signature gained four parameters
  (`intent_confidence`, `hyde_query`, `original_query`,
  `raw_chunk_count`).

### E.3 Modified — `ui/components/chat_panel.py`

- `_stream_chat` now collects `trace` events into a list and updates a
  live placeholder (`🧠 Agent thinking…`) as they arrive.
- Live placeholder is cleared once the stream completes; the same
  events are then rendered into a persistent collapsible expander
  (`🧠 Agent trace (N steps)`) below the answer.
- `_format_trace_line` translates each event into a human-readable
  markdown line (emoji + bold phase + key payload fields).
- Conversation history rendering reads the saved `trace` list back
  from `st.session_state.messages` so prior agent traces stay visible
  on page reload.

---

## Theme F — Backwards-Compat / Fix Release (already shipped in 0.2)

Captured in detail in `CHANGELOG.md` under `[0.2.0]`. Key items:

- DuckDB seeder rewritten for v1.x (no `executescript`).
- `config.py` → `pm_config.py` to avoid PyPI `config` package clash.
- `pyproject.toml` adds `pythonpath = ["."]` and warning filters.
- Approval gate persists tool result before `st.rerun()`.
- Embedders import fixed for sentence-transformers 3.x.
- Validators switched to Pydantic v2 (`min_length` not `min_items`).

---

## Summary table — files touched in this branch

| Path                                              | Theme(s) | Change type             |
|---------------------------------------------------|----------|-------------------------|
| `agent/llm_router.py`                             | A        | **new file**            |
| `agent/agent_loop.py`                             | A,B,E    | heavy refactor          |
| `retrieval/intent_classifier.py`                  | A,C      | rewritten (two-stage)   |
| `retrieval/hyde.py`                               | A        | router migration        |
| `retrieval/reranker.py`                           | D        | sigmoid normalisation   |
| `retrieval/context_builder.py`                    | D        | min-score filter        |
| `ingestion/summary_generator.py`                  | A        | router migration        |
| `api/main.py`                                     | A        | new `/agent/stats` route|
| `api/routers/chat.py`                             | B,E      | trace bridge + intent fwd|
| `ui/components/chat_panel.py`                     | D,E      | citation polish + trace |
| `tests/unit/test_agent_intent_routing.py`         | B        | **new file**            |
| `tests/unit/test_intent_keyword_classifier.py`    | C        | **new file**            |
| `.env.example`                                    | A        | secondary key var       |
| `docs/CHANGES_DETAILED.md` (this file)            | —        | **new file**            |
| `docs/INTERNALS.md`                               | —        | **new file**            |
| `docs/SPEC.md`                                    | —        | **new file**            |
