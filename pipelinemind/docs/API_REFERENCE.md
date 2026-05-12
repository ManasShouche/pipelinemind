# PipelineMind — API Reference

Base URL: `http://localhost:8000`
Interactive docs: `http://localhost:8000/docs`
All routes prefixed: `/api/v1/`

---

## Authentication

No authentication is required for local development. In production, add an API gateway
or OAuth2 middleware before the FastAPI app.

---

## Chat

### POST /api/v1/chat

Stream a chat response via Server-Sent Events.

**Request body:**

```json
{
  "message": "Why does the orders pipeline use MERGE?",
  "conversation_history": [
    {"role": "user", "content": "..."},
    {"role": "assistant", "content": "..."}
  ],
  "pipeline_filter": "orders",
  "intent_override": null
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `message` | string | Yes | User query (1–4000 chars) |
| `conversation_history` | array | No | Prior turns for multi-turn context |
| `pipeline_filter` | string | No | Filter retrieval to a specific pipeline |
| `intent_override` | string | No | Force a specific intent: `CODE_QA`, `CATALOGUE`, `HEALTH`, `ACTION`, `GENERAL` |

**SSE Event stream:**

```
event: retrieval_complete
data: {"confidence_score": 0.847, "has_pii": false, "citations": [...], "low_confidence": false}
event: token
data: {"text": "The orders pipeline "}
event: token
data: {"text": "uses MERGE because "}
event: done
data: {"full_response": "...", "tool_calls": [], "iterations": 1, "latency_ms": 923.4}
```

**Approval required event** (when agent selects a state-altering tool):

```
event: approval_required
data: {"tool_name": "trigger_dq_check", "tool_args": {"table_name": "orders_fact", "rules_preset": "standard"}, "message": "I need to run..."}
```

---

### POST /api/v1/chat/approve

Execute or deny a pending tool call after human approval.

**Request body:**

```json
{
  "tool_name": "trigger_dq_check",
  "tool_args": {"table_name": "orders_fact", "rules_preset": "standard"},
  "call_id": "pending",
  "approved": true
}
```

**Response (approved):**

```json
{
  "status": "executed",
  "result": "DQ check passed with score 0.875...",
  "tool_calls": [{"tool": "trigger_dq_check", "approved": true}]
}
```

**Response (denied):**

```json
{"status": "denied", "message": "Tool execution denied by user."}
```

---

## Pipelines

### GET /api/v1/pipelines

List all pipelines with their latest run status and success rates.

**Response:**

```json
[
  {
    "pipeline_id": "orders",
    "total_runs": 150,
    "success_rate": 96.67,
    "last_run": "2024-03-15T14:00:00",
    "last_status": "success"
  }
]
```

---

### GET /api/v1/pipelines/{pipeline_id}/status

Fetch run history and current status for a specific pipeline.

**Query parameters:**

| Parameter | Type | Default | Description |
|---|---|---|---|
| `lookback_hours` | integer | 24 | Hours of history to return |

**Response:**

```json
{
  "status": "success",
  "last_run": "2024-03-15T14:00:00",
  "slo_pct": 96.67,
  "failures": [
    {"run_id": "abc123", "start_time": "2024-03-10T02:00:00", "error": "Connection timeout", "duration_secs": 12.3}
  ],
  "total_runs": 30,
  "pipeline_id": "orders",
  "avg_duration_secs": 87.4
}
```

---

### GET /api/v1/pipelines/{pipeline_id}/slo

SLO adherence report over a rolling window.

**Query parameters:**

| Parameter | Type | Default | Description |
|---|---|---|---|
| `window_days` | integer | 7 | Rolling window in days |

**Response:**

```json
{
  "pipeline_id": "orders",
  "window_days": 7,
  "slo_target": 99.5,
  "actual_pct": 96.67,
  "breach_events": ["run_id_1", "run_id_2"],
  "total_runs": 42,
  "compliant": false
}
```

---

## Data Catalogue

### GET /api/v1/catalogue/tables

List all tables in the data catalogue.

**Response:**

```json
[
  {
    "table_id": "t001",
    "table_name": "orders_fact",
    "schema": "marts",
    "description": "Orders fact table...",
    "domain": "finance",
    "pii_flag": false,
    "tags": ["orders", "finance", "gold"],
    "row_count": 2847293
  }
]
```

---

### GET /api/v1/catalogue/tables/{table_name}

Detailed table metadata including all columns and PII classifications.

**Response:**

```json
{
  "table": {
    "name": "dim_users",
    "schema": "dims",
    "description": "SCD Type-2 users dimension...",
    "domain": "users",
    "pii_flag": true,
    "tags": ["users", "dimension", "pii"],
    "row_count": 185432
  },
  "columns": [
    {"name": "user_id",    "type": "varchar(36)", "pii_class": null,       "nullable": false, "description": "Natural key"},
    {"name": "email",      "type": "varchar(320)","pii_class": "PII_HIGH", "nullable": false, "description": "User email"},
    {"name": "phone_number","type": "varchar(20)","pii_class": "PII_HIGH", "nullable": true,  "description": null}
  ]
}
```

---

### GET /api/v1/catalogue/lineage/{table_name}

Upstream and downstream table lineage graph.

**Query parameters:**

| Parameter | Type | Default | Description |
|---|---|---|---|
| `depth` | integer | 2 | Number of hops to traverse |

**Response:**

```json
{
  "center_table": "orders_fact",
  "depth": 2,
  "nodes": [
    {"table": "orders_fact", "domain": "finance", "pii_flag": false, "row_count": 2847293},
    {"table": "stg_orders",  "domain": "finance", "pii_flag": false, "row_count": 0}
  ],
  "edges": [
    {"source": "stg_orders", "source_column": "order_id", "target": "orders_fact", "target_column": "order_id", "transformation": "merge"}
  ],
  "pii_nodes": [],
  "node_count": 2,
  "edge_count": 1
}
```

---

### GET /api/v1/catalogue/pii

List all PII-tagged tables and columns.

**Query parameters:**

| Parameter | Type | Default | Description |
|---|---|---|---|
| `domain` | string | null | Filter by domain (e.g., `users`, `finance`) |

**Response:**

```json
[
  {
    "table": "dim_users",
    "domain": "users",
    "sensitivity_level": "high",
    "columns": [
      {"column_name": "email",        "pii_class": "PII_HIGH",   "retention_days": 730},
      {"column_name": "phone_number", "pii_class": "PII_HIGH",   "retention_days": 730},
      {"column_name": "full_name",    "pii_class": "PII_MEDIUM", "retention_days": 1095}
    ]
  }
]
```

---

## Data Quality

### POST /api/v1/dq/trigger

Trigger a DQ check against a table (assumes human approval already obtained).

**Request body:**

```json
{
  "table_name": "orders_fact",
  "rules_preset": "standard"
}
```

`rules_preset` options: `minimal`, `standard`, `strict`

**Response:**

```json
{
  "passed": true,
  "failed_rules": [],
  "passed_rules": ["expect_table_row_count_to_be_between", "expect_column_values_to_not_be_null(order_id)"],
  "score": 1.0,
  "run_id": "a3f9c1",
  "table_name": "orders_fact",
  "rules_preset": "standard"
}
```

---

### GET /api/v1/dq/results/{run_id}

Retrieve results for a previous DQ run.

**Response:**

```json
{"run_id": "a3f9c1", "status": "completed", "message": "Results available in GE data docs."}
```

---

## Impact Analysis

### POST /api/v1/impact/analyze

What-If Impact Engine: trace downstream blast radius before a schema change.

**Request body:**

```json
{
  "changed_table": "stg_users",
  "dropped_columns": ["user_id", "email"]
}
```

**Response:**

```json
{
  "changed_table": "stg_users",
  "dropped_columns": ["user_id", "email"],
  "affected_models": ["orders_fact", "sessions_agg"],
  "affected_dashboards": ["revenue_dashboard (Metabase)", "vw_revenue_by_tier"],
  "affected_ml": ["ml_feature_store (user propensity model)"],
  "risk_score": 0.85,
  "recommended_action": "HIGH RISK: Dropping [user_id, email] from stg_users will break...",
  "pii_columns_affected": true,
  "lineage_detail": [
    {"target_table": "orders_fact", "target_column": "customer_id", "source_column": "user_id", "transformation": "direct"}
  ]
}
```

---

## Observability

### GET /api/v1/health

System health check.

**Response:**

```json
{
  "status": "ok",
  "environment": "development",
  "duckdb": "data/pipelinemind.db",
  "chroma": "data/chroma_db"
}
```

---

### GET /api/v1/schema-drift

Latest schema drift events from the MCP Resource polling mechanism.

**Response:**

```json
{
  "drift_events": [],
  "polled_at": "2024-03-15T14:23:01.000Z",
  "status": "clean"
}
```

When drift is detected:

```json
{
  "drift_events": [
    {
      "table": "orders_fact",
      "added_columns": ["new_col"],
      "dropped_columns": [],
      "type_changes": [],
      "baseline_at": "2024-03-15T02:00:00Z",
      "severity": "LOW"
    }
  ],
  "status": "drift_detected"
}
```

---

### GET /metrics

Prometheus metrics endpoint.

```
pipelinemind_requests_total{method="POST",endpoint="/api/v1/chat"} 42
pipelinemind_request_latency_seconds_bucket{endpoint="/api/v1/chat",le="1.0"} 38
```
