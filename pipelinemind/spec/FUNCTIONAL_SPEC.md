# PipelineMind — Functional Specification

Version: 0.3
Audience: Product, mentors, and reviewers. No implementation detail —
that lives in `TECHNICAL_SPEC.md`.

---

## 1. Purpose

PipelineMind is a conversational AI assistant for Data Engineers. It
replaces the constant context-switch between code editor, data catalogue
UI, lineage tool, and pipeline monitoring dashboard with a single chat
surface that can answer questions, surface relationships, and take
guarded actions.

### 1.1 Problem statement

A Data Engineer typically juggles:

- A code repo (pipeline source, SQL, dbt models).
- A data catalogue (table schemas, PII tags).
- A lineage tool (upstream / downstream relationships).
- A monitoring dashboard (run history, SLO adherence).
- A data-quality runner (Great Expectations or similar).

Routine questions — *"why does this pipeline use MERGE?"*, *"what
downstream breaks if I drop this column?"*, *"did the orders pipeline
fail today?"* — require a context switch between three or four of those
tools. The cost is measured in interrupted focus, not minutes.

### 1.2 Solution

A chat assistant grounded in the team's own pipeline corpus
(code + catalogue + run logs) that can:

- Answer questions about the codebase with citations.
- Explore the catalogue and lineage on demand.
- Report pipeline health and SLO adherence.
- Trigger data-quality checks — but only after explicit human approval.

### 1.3 Goals

- Reduce mean time-to-answer for routine DE questions.
- Prevent production incidents caused by un-traced schema changes
  (the "What-If" impact engine).
- Keep humans in the loop for any state-altering action.

### 1.4 Non-goals (this milestone)

- Replacing the catalogue, lineage, or monitoring UI as the system
  of record.
- Multi-tenant authentication and role-based access.
- Live ingestion from production warehouses (Snowflake / BigQuery
  connectors are scaffolds only).
- Autonomous pipeline self-healing (human gate is non-negotiable).

---

## 2. Personas

### 2.1 Data Engineer (primary)

- Lives in pipeline code and SQL.
- Owns a handful of pipelines end-to-end.
- Triages failures, ships changes, and is paged when SLOs miss.
- Wants: fast answers about their own code and quick lineage checks
  before risky merges.

### 2.2 Analytics Engineer (secondary)

- Builds and maintains dbt models that consume the engineer's tables.
- Wants: catalogue exploration, PII discovery, and an early warning
  when an upstream pipeline is about to change.

### 2.3 Data Platform Lead (tertiary)

- Operates the wider platform.
- Wants: SLO health snapshots, drift alerts, and an audit trail of
  what the assistant has done (every tool call is logged).

---

## 3. Core capabilities

### 3.1 Codebase Q&A

| Capability                | Description                                                              |
|---------------------------|--------------------------------------------------------------------------|
| Free-text code questions  | "Why does the orders pipeline use MERGE?"                                |
| Cite source               | Each answer cites file, chunk type, function name, and git commit hash. |
| Multi-file synthesis      | The assistant draws on multiple chunks across files when relevant.       |
| Confidence indication     | A confidence pill shows how strongly the retrieved context supports the answer. |

### 3.2 Catalogue exploration

| Capability                | Description                                                              |
|---------------------------|--------------------------------------------------------------------------|
| Table & column discovery  | "What columns exist in `dim_users`?"                                     |
| PII discovery             | "Which tables contain PII?", "What PII is in `dim_users`?"               |
| Lineage queries           | "What is the lineage DAG for `vw_revenue_by_tier`?"                      |
| What-If impact analysis   | "What breaks if I drop `user_id` from `stg_users`?"                      |

### 3.3 Pipeline health

| Capability                | Description                                                              |
|---------------------------|--------------------------------------------------------------------------|
| Current status            | "Did the orders pipeline fail today?"                                    |
| Recent runs               | "Show me the last 24 h of runs for `pipeline_x`."                        |
| SLO adherence             | "What is our SLO breach rate for the last 7 days?"                       |
| Failure triage hints      | Surface error messages from recent failures alongside the status.        |

### 3.4 Agentic actions

| Action                    | Approval gate? | Description                                          |
|---------------------------|----------------|------------------------------------------------------|
| `trigger_dq_check`        | **Yes**        | Run a Great Expectations DQ suite on a table.        |
| `get_pipeline_status`     | No             | Read-only — fetch run status / history.              |
| `get_slo_report`          | No             | Read-only — SLO adherence over a rolling window.     |
| `get_lineage_graph`       | No             | Read-only — upstream/downstream graph.               |
| `analyze_lineage_impact`  | No             | Read-only — predict blast radius of a schema change. |
| `search_pii_tables`       | No             | Read-only — list PII-tagged tables.                  |

### 3.5 Schema drift alerting

The assistant detects added / dropped / type-changed columns versus a
recorded baseline and surfaces them as a sidebar banner. The banner
shows the table name and the nature of the change.

### 3.6 Live agent trace

For every answer, the user can see exactly what the assistant did:
which intent was detected, whether HyDE expansion fired, how many
documents were retrieved, which tools were called and with what
arguments, and how long each step took. This is visible both live
while the answer streams and as a collapsible record below the
finished answer.

---

## 4. User workflows

### 4.1 Workflow A — Codebase Q&A

1. User opens the Chat page.
2. Types: *"Why does the orders pipeline use MERGE instead of
   INSERT OVERWRITE?"*
3. Sees:
   - An "Intent: `CODE_QA`" pill appear at the top of the response.
   - The answer stream into the chat bubble.
   - A "Sources (N relevant)" expander listing the cited files
     with relevance percentages.
   - A confidence pill colour-coded by how confident the retrieval
     was (green ≥ 70 %, orange ≥ 50 %, red below).
   - The "Agent trace" expander with a short trace (intent →
     retrieval → direct generation → done).

### 4.2 Workflow B — Lineage exploration

1. User asks: *"What is the lineage DAG for `vw_revenue_by_tier`?"*
2. Intent classifier resolves to `CATALOGUE` (via the keyword
   fast-path, no LLM call needed).
3. The agent calls `get_lineage_graph` exactly once.
4. The answer summarises upstream and downstream tables; the trace
   shows the single tool call with its duration; citations point
   to the catalogue source.

### 4.3 Workflow C — What-If impact (the core innovation)

1. User asks: *"What happens if I drop `user_id` from `stg_users`?"*
2. Intent resolves to `ACTION`.
3. The agent calls `analyze_lineage_impact`.
4. The response lists every downstream model, dashboard, and ML
   feature that touches `user_id`, plus a risk score and a recommended
   action.
5. The user sees the answer *before* making the change in their code
   editor — preventing a broken merge.

### 4.4 Workflow D — DQ check with approval gate

1. User asks: *"Run a data-quality check on `stg_users`."*
2. Intent resolves to `ACTION`.
3. The agent identifies `trigger_dq_check` as the right tool, but
   instead of executing it, returns an approval-required message:
   > *I need to run `trigger_dq_check` with parameters
   > `{table_name: "stg_users"}`. Please approve or deny this
   > action in the UI.*
4. The UI renders the **Approval Gate** with `Approve` / `Deny`
   buttons and the exact arguments that will be used.
5. On approval: the tool executes, result is posted back to chat,
   trace shows the tool execution and result preview.
6. On denial: nothing runs, chat continues, audit log records the
   denial.

### 4.5 Workflow E — Schema drift triage

1. Operator opens the Chat page.
2. Sidebar banner: *"Schema drift detected on `dim_users`:
   2 columns added, 1 type changed."*
3. Operator follows the breadcrumb into the Catalogue page to see
   the column diff against the baseline.
4. Operator asks the assistant: *"Which pipelines write to
   `dim_users`?"* to identify the source of the drift.

---

## 5. Functional requirements

Each requirement is testable in isolation.

### 5.1 Conversational interface

| ID    | Requirement                                                                                            |
|-------|--------------------------------------------------------------------------------------------------------|
| F-01  | The system shall accept free-text questions through a chat UI.                                         |
| F-02  | The system shall stream the answer token-by-token, not as a single blob.                               |
| F-03  | The system shall persist the conversation within a session and replay it across page rerenders.        |
| F-04  | The system shall accept slash commands (`/diagnose_pipeline <id>`) and route them through MCP Prompts. |

### 5.2 Intent and retrieval

| ID    | Requirement                                                                                            |
|-------|--------------------------------------------------------------------------------------------------------|
| F-10  | The system shall classify every query into exactly one of: CODE_QA, CATALOGUE, HEALTH, ACTION, GENERAL.|
| F-11  | The system shall display the detected intent to the user.                                              |
| F-12  | The system shall retrieve and rank relevant chunks for every intent except GENERAL.                    |
| F-13  | The system shall display citations for every answer that used retrieved context.                       |
| F-14  | Citations shall include file, chunk type, function name (if any), git commit hash, and a relevance %.   |
| F-15  | Citations with relevance below the configured threshold shall be hidden from the user.                  |
| F-16  | The system shall display a confidence indicator alongside the answer.                                   |

### 5.3 Tools and actions

| ID    | Requirement                                                                                            |
|-------|--------------------------------------------------------------------------------------------------------|
| F-20  | The system shall expose six tools: `trigger_dq_check`, `get_pipeline_status`, `get_lineage_graph`, `analyze_lineage_impact`, `search_pii_tables`, `get_slo_report`. |
| F-21  | The system shall restrict which tools the agent may call based on the detected intent.                 |
| F-22  | The system shall block `trigger_dq_check` behind a human approval gate.                                |
| F-23  | The approval gate shall display the tool name and exact arguments before execution.                    |
| F-24  | A denied approval shall result in zero side effects.                                                   |

### 5.4 Trace and transparency

| ID    | Requirement                                                                                            |
|-------|--------------------------------------------------------------------------------------------------------|
| F-30  | The system shall emit a live trace of each decision: intent, retrieval outcome, agent start, per-tool start/end, completion. |
| F-31  | The live trace shall update as events occur, not only after the answer is complete.                    |
| F-32  | The completed trace shall remain visible (collapsed) below the answer after streaming finishes.        |
| F-33  | The trace shall record per-tool execution duration in milliseconds.                                    |

### 5.5 PII handling

| ID    | Requirement                                                                                            |
|-------|--------------------------------------------------------------------------------------------------------|
| F-40  | The system shall redact PII patterns (email, phone, SSN, password, secret, token) before passing context to the LLM. |
| F-41  | The system shall mark its response with a visible PII warning when sensitive columns are referenced.    |
| F-42  | The system shall not emit unredacted PII values into log lines.                                         |

### 5.6 Schema drift

| ID    | Requirement                                                                                            |
|-------|--------------------------------------------------------------------------------------------------------|
| F-50  | The system shall compare current column inventories against recorded snapshots on a fixed schedule.    |
| F-51  | The system shall surface column-level changes (added, dropped, type-changed) as a sidebar banner.      |
| F-52  | The system shall return an empty (not error) drift result when the database has not yet been seeded.   |

---

## 6. UI requirements

### 6.1 Layout

- A persistent left sidebar showing brand, quick-shortcut prompts,
  and the schema drift banner.
- A multi-page main area with at least: Chat, Health, Catalogue.
- Each page renders independently and is navigable via the
  Streamlit sidebar.

### 6.2 Chat page

| Element                | Behaviour                                                                  |
|------------------------|----------------------------------------------------------------------------|
| Message history        | User and assistant turns rendered chronologically.                         |
| Streaming bubble       | Tokens stream in with a blinking cursor until the answer settles.          |
| Sources expander       | Below each answer, lists cited files with file, chunk type, relevance %.   |
| Confidence pill        | Below citations, coloured by confidence band.                              |
| Intent pill            | Below the confidence pill, shows the detected intent.                      |
| PII warning            | Yellow banner if the answer references PII columns.                        |
| Agent trace expander   | Below all of the above, lists every decision step taken by the agent.      |
| Live trace placeholder | Above the answer, replaced once streaming completes.                       |
| Approval gate          | Inline panel with Approve / Deny when a state-altering tool is requested.  |
| Chat input             | Bottom of the page, persistent.                                            |

### 6.3 Health page

- A list of pipelines and their current status.
- Recent failures with error message previews.
- SLO adherence per pipeline.

### 6.4 Catalogue page

- A list of catalogue tables with PII tags.
- An interactive lineage graph rendered with a DAG layout.
- Drift indicators if any table has detected drift since the baseline.

---

## 7. Acceptance criteria

| #     | Criterion                                                                                              |
|-------|--------------------------------------------------------------------------------------------------------|
| AC-01 | Asking *"Why does the orders pipeline use MERGE?"* returns CODE_QA intent with at least one citation.  |
| AC-02 | Asking *"What PII is in `dim_users`?"* returns CATALOGUE intent + a PII column list.                   |
| AC-03 | Asking *"What is the lineage DAG for `vw_revenue_by_tier`?"* returns lineage with one tool call only.  |
| AC-04 | Asking *"What happens if I drop `user_id` from `stg_users`?"* returns ACTION intent + impact summary.  |
| AC-05 | Asking *"Did the orders pipeline fail today?"* returns HEALTH intent + status from the last 24 h.      |
| AC-06 | Asking *"Run a DQ check on `stg_users`"* triggers the approval gate; denial executes nothing.          |
| AC-07 | Every answer renders a "🧠 Agent trace (N steps)" expander with at least the expected decision points. |
| AC-08 | The schema-drift sidebar banner is non-empty when fixtures contain drift, and absent otherwise.        |
| AC-09 | Citations with relevance below the configured threshold are hidden from the user.                      |
| AC-10 | Approval gate denial records the denial event in the chat history.                                     |

---

## 8. Out of scope

- Multi-tenant authentication, RBAC, audit trail per user.
- Real-time ingestion from production warehouses (the fixtures
  represent a synthetic snapshot).
- Cost-per-query estimation displayed inline.
- Voice input / output.
- Autonomous schema-change merges (the human gate is non-negotiable).
- Per-user conversation persistence across browser sessions
  (in-session only for this milestone).

---

## 9. Glossary

| Term                  | Definition                                                                                              |
|-----------------------|--------------------------------------------------------------------------------------------------------|
| Intent                | One of 5 categories that determines retrieval shape and which tools the agent may call.                |
| Retrieval             | The process of finding relevant chunks in the indexed corpus for a given query.                        |
| Citation              | A reference to a specific chunk that supports a claim in the answer.                                   |
| Tool                  | A typed function the agent may invoke (e.g. `get_lineage_graph`).                                      |
| Approval gate         | The UI step that requires explicit human confirmation before a state-altering tool runs.               |
| What-If impact        | A predictive analysis of which downstream assets a proposed schema change would break.                 |
| Schema drift          | The set of column-level differences between the current catalogue and a recorded baseline.             |
| MCP                   | Model Context Protocol — the standard transport used to expose tools, resources, and prompts.          |
| Trace                 | The recorded sequence of decisions the agent made while producing an answer.                           |
