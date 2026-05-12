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

```
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
```

---

## Ingestion Pipeline

### Flow

```
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
```

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

```
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
              ┌───────────────┴───────────────┐
              │                               │
              ▼                               ▼
      ChromaRetriever                 BM25Retriever
    (cosine HNSW, top-20)          (BM25Okapi scores, top-20)
              │                               │
              └───────────────┬───────────────┘
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
```

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

```
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
       ┌──────┴──────┐
       │             │
      Yes            No
       │             │
       ▼             ▼
  Pause loop    Pydantic validation
  Return        (validators.py)
  approval_req  │
  event to UI   ├── Invalid params ──► Return error to LLM (self-correction)
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
```

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

```
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
```

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

```
GET /api/v1/health
→ {"status": "ok", "environment": "development", "duckdb": "...", "chroma": "..."}
```

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
