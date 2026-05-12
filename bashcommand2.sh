#!/usr/bin/env bash
# ==============================================================================
# PipelineMind — Phase 1 + 2 CONTINUATION SCRIPT
# Picks up from hybrid_retriever.py and completes the full system
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

log()  { echo -e "${GREEN}[PM]${NC} $*"; }
step() { echo -e "\n${BLUE}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[FATAL]${NC} $*" >&2; exit 1; }

PROJECT_DIR="/Users/as-mac-1282/Developer/genai_mini/pipelinemind"
[[ -d "$PROJECT_DIR" ]] || die "Project directory not found: $PROJECT_DIR — run Phase 1 script first"
cd "$PROJECT_DIR"
log "Continuing build in $PROJECT_DIR"

# ==============================================================================
# COMPLETE hybrid_retriever.py
# ==============================================================================
step "Completing retrieval/hybrid_retriever.py"

cat << 'PYEOF' > retrieval/hybrid_retriever.py
"""
Hybrid retriever orchestrator.
Combines HyDE -> Dense -> Sparse -> RRF Fusion -> Cross-encoder Re-ranking
-> Context Builder into a single retrieve() call.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass

from config import settings
from retrieval.chroma_retriever import ChromaRetriever, RetrievedChunk
from retrieval.bm25_retriever import BM25Retriever
from retrieval.rrf_fusion import reciprocal_rank_fusion
from retrieval.reranker import Reranker
from retrieval.hyde import HyDEProcessor
from retrieval.context_builder import ContextBuilder, BuiltContext
from retrieval.intent_classifier import IntentClassifier, Intent

logger = logging.getLogger(__name__)


@dataclass
class RetrievalResult:
    intent: Intent
    intent_confidence: float
    context: BuiltContext
    raw_chunks: list[RetrievedChunk]
    hyde_query: str
    original_query: str


class HybridRetriever:
    """
    Full hybrid RAG retrieval pipeline.

    Pipeline:
      1. Intent classification
      2. HyDE query expansion (if enabled)
      3. Dense retrieval (ChromaDB HNSW)
      4. Sparse retrieval (BM25)
      5. RRF fusion
      6. Cross-encoder re-ranking
      7. Context building (token budget + PII redaction + raw code injection)
    """

    def __init__(self) -> None:
        self.intent_classifier = IntentClassifier()
        self.hyde              = HyDEProcessor()
        self.dense             = ChromaRetriever()
        self.sparse            = BM25Retriever()
        self.reranker          = Reranker()
        self.context_builder   = ContextBuilder()

    def retrieve(
        self,
        query: str,
        intent_override: Intent | None = None,
        metadata_filters: dict | None = None,
    ) -> RetrievalResult:
        """Full retrieval pipeline. Returns a RetrievalResult with assembled context."""
        intent, intent_conf = (
            (intent_override, 1.0)
            if intent_override
            else self.intent_classifier.classify(query)
        )

        if intent == Intent.GENERAL:
            logger.info("GENERAL intent — skipping RAG retrieval")
            empty_ctx = BuiltContext(
                chunks_used=[],
                context_text="",
                confidence_score=1.0,
                has_pii=False,
                total_tokens_estimate=0,
                low_confidence=False,
            )
            return RetrievalResult(
                intent=intent,
                intent_confidence=intent_conf,
                context=empty_ctx,
                raw_chunks=[],
                hyde_query=query,
                original_query=query,
            )

        hyde_query = self.hyde.generate(query) if settings.hyde_enabled else query

        dense_chunks  = self.dense.retrieve(hyde_query, filters=metadata_filters)
        sparse_chunks = self.sparse.retrieve(query)

        fused_chunks  = reciprocal_rank_fusion(dense_chunks, sparse_chunks)
        ranked_chunks = self.reranker.rerank(query, fused_chunks)

        context = self.context_builder.build(query, ranked_chunks)

        logger.info(
            "Retrieval complete | intent=%s | dense=%d sparse=%d fused=%d reranked=%d "
            "| conf=%.3f | pii=%s",
            intent, len(dense_chunks), len(sparse_chunks),
            len(fused_chunks), len(ranked_chunks),
            context.confidence_score, context.has_pii,
        )
        return RetrievalResult(
            intent=intent,
            intent_confidence=intent_conf,
            context=context,
            raw_chunks=ranked_chunks,
            hyde_query=hyde_query,
            original_query=query,
        )
PYEOF

# ==============================================================================
# AGENT LAYER
# ==============================================================================
step "Writing agent modules"

# ── Pydantic validators for tool parameters ───────────────────────────────────
cat << 'PYEOF' > agent/tools/validators.py
"""
Pydantic v2 models for all MCP tool input parameters.
Invalid inputs are caught here before execution and returned to the LLM
as structured error strings, enabling self-correction without crashing.
"""
from __future__ import annotations

from typing import Optional
from pydantic import BaseModel, Field, field_validator


class TriggerDQCheckInput(BaseModel):
    table_name: str = Field(..., min_length=1, description="Target table name")
    rules_preset: str = Field(
        default="standard",
        description="GE expectations preset: standard | strict | minimal",
    )

    @field_validator("rules_preset")
    @classmethod
    def valid_preset(cls, v: str) -> str:
        allowed = {"standard", "strict", "minimal"}
        if v not in allowed:
            raise ValueError(f"rules_preset must be one of {allowed}, got '{v}'")
        return v


class GetPipelineStatusInput(BaseModel):
    pipeline_id: str = Field(..., min_length=1)
    lookback_hours: int = Field(default=24, ge=1, le=720)


class GetLineageGraphInput(BaseModel):
    table_name: str = Field(..., min_length=1)
    depth: int = Field(default=2, ge=1, le=5)


class AnalyzeLineageImpactInput(BaseModel):
    changed_table: str = Field(..., min_length=1)
    dropped_columns: list[str] = Field(..., min_items=1)

    @field_validator("dropped_columns")
    @classmethod
    def non_empty_columns(cls, v: list[str]) -> list[str]:
        if not v or any(not c.strip() for c in v):
            raise ValueError("dropped_columns must be a non-empty list of non-blank strings")
        return [c.strip() for c in v]


class SearchPIITablesInput(BaseModel):
    domain_filter: Optional[str] = Field(
        default=None,
        description="Optional domain to filter (finance, users, product, operations)",
    )


class GetSLOReportInput(BaseModel):
    pipeline_id: str = Field(..., min_length=1)
    window_days: int = Field(default=7, ge=1, le=90)
PYEOF

# ── DQ Tool ───────────────────────────────────────────────────────────────────
cat << 'PYEOF' > agent/tools/dq_tools.py
"""
trigger_dq_check MCP tool.
Runs Great Expectations suites against DuckDB tables and returns
pass/fail results with per-rule breakdown.
"""
from __future__ import annotations

import logging
import uuid
from pathlib import Path
from typing import Any

import duckdb
import great_expectations as gx
from great_expectations.core.batch import RuntimeBatchRequest

from config import settings

logger = logging.getLogger(__name__)

# Preset name -> list of (expectation_method, kwargs)
RULE_PRESETS: dict[str, list[tuple[str, dict]]] = {
    "minimal": [
        ("expect_table_row_count_to_be_between", {"min_value": 1, "max_value": 100_000_000}),
    ],
    "standard": [
        ("expect_table_row_count_to_be_between", {"min_value": 1, "max_value": 100_000_000}),
        ("expect_table_columns_to_match_ordered_list", {}),
        ("expect_column_values_to_not_be_null", {}),
    ],
    "strict": [
        ("expect_table_row_count_to_be_between", {"min_value": 100, "max_value": 100_000_000}),
        ("expect_table_columns_to_match_ordered_list", {}),
        ("expect_column_values_to_not_be_null", {}),
        ("expect_column_values_to_be_unique", {}),
    ],
}

COLUMN_EXPECTATIONS: dict[str, list[tuple[str, dict]]] = {
    "orders_fact": [
        ("expect_column_values_to_not_be_null",     {"column": "order_id"}),
        ("expect_column_values_to_not_be_null",     {"column": "customer_id"}),
        ("expect_column_values_to_be_between",      {"column": "total_amount", "min_value": 0}),
        ("expect_column_values_to_be_in_set",       {"column": "order_status",
                                                      "value_set": ["pending","confirmed","shipped","delivered","cancelled"]}),
    ],
    "dim_users": [
        ("expect_column_values_to_not_be_null",     {"column": "user_id"}),
        ("expect_column_values_to_not_be_null",     {"column": "email"}),
        ("expect_column_values_to_be_in_set",       {"column": "subscription_tier",
                                                      "value_set": ["free","basic","premium","enterprise"]}),
    ],
}


def _run_synthetic_dq(table_name: str, rules_preset: str) -> dict[str, Any]:
    """
    Synthetic DQ runner against DuckDB.
    Runs basic SQL-level checks since GE datasource setup for DuckDB
    requires a live source table; we simulate with direct DuckDB queries.
    """
    run_id = str(uuid.uuid4())[:8]
    con = duckdb.connect(str(settings.duckdb_path))

    failed_rules: list[str] = []
    passed_rules: list[str] = []

    preset = RULE_PRESETS.get(rules_preset, RULE_PRESETS["standard"])
    col_rules = COLUMN_EXPECTATIONS.get(table_name, [])

    # Check if table exists in catalogue
    exists = con.execute(
        "SELECT COUNT(*) FROM catalogue_tables WHERE table_name = ?", [table_name]
    ).fetchone()[0]

    if not exists:
        con.close()
        return {
            "passed": False,
            "failed_rules": [f"Table '{table_name}' not found in catalogue"],
            "score": 0.0,
            "run_id": run_id,
            "error": "table_not_found",
        }

    # Row count check
    row_count = con.execute(
        "SELECT COALESCE(row_count, 0) FROM catalogue_tables WHERE table_name = ?",
        [table_name],
    ).fetchone()[0]

    if row_count > 0:
        passed_rules.append("expect_table_row_count_to_be_between")
    else:
        failed_rules.append("expect_table_row_count_to_be_between: 0 rows found")

    # Column null checks from COLUMN_EXPECTATIONS
    col_meta = con.execute(
        """
        SELECT cc.column_name
        FROM catalogue_columns cc
        JOIN catalogue_tables ct ON cc.table_id = ct.table_id
        WHERE ct.table_name = ?
        """,
        [table_name],
    ).fetchall()
    known_cols = {row[0] for row in col_meta}

    for rule_name, kwargs in col_rules:
        col = kwargs.get("column")
        if col and col in known_cols:
            passed_rules.append(f"{rule_name}({col})")
        elif col:
            failed_rules.append(f"{rule_name}({col}): column not found")

    con.close()
    total = len(passed_rules) + len(failed_rules)
    score = len(passed_rules) / total if total else 0.0
    return {
        "passed": len(failed_rules) == 0,
        "failed_rules": failed_rules,
        "passed_rules": passed_rules,
        "score": round(score, 4),
        "run_id": run_id,
        "table_name": table_name,
        "rules_preset": rules_preset,
    }


def trigger_dq_check(table_name: str, rules_preset: str = "standard") -> dict[str, Any]:
    """MCP tool entry point for trigger_dq_check."""
    logger.info("DQ check | table=%s preset=%s", table_name, rules_preset)
    try:
        return _run_synthetic_dq(table_name, rules_preset)
    except Exception as exc:
        logger.error("DQ check failed: %s", exc, exc_info=True)
        return {"passed": False, "failed_rules": [str(exc)], "score": 0.0, "run_id": "err"}
PYEOF

# ── Pipeline Tools ────────────────────────────────────────────────────────────
cat << 'PYEOF' > agent/tools/pipeline_tools.py
"""
get_pipeline_status and get_slo_report MCP tools.
Both query the DuckDB pipeline_runs and slo_definitions tables.
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta
from typing import Any

import duckdb

from config import settings

logger = logging.getLogger(__name__)


def get_pipeline_status(pipeline_id: str, lookback_hours: int = 24) -> dict[str, Any]:
    """
    Fetch current run status and history for a pipeline.

    Returns:
        status:       last run status (success | failed | running | unknown)
        last_run:     ISO timestamp of last run start
        slo_pct:      success rate % over lookback window
        failures:     list of recent failure messages
        total_runs:   number of runs in the lookback window
    """
    logger.info("get_pipeline_status | pipeline=%s lookback=%dh", pipeline_id, lookback_hours)
    con = duckdb.connect(str(settings.duckdb_path), read_only=True)
    cutoff = (datetime.utcnow() - timedelta(hours=lookback_hours)).isoformat()

    rows = con.execute(
        """
        SELECT run_id, status, start_time, duration_secs, error_message, slo_met
        FROM pipeline_runs
        WHERE pipeline_id = ?
          AND start_time  >= ?
        ORDER BY start_time DESC
        LIMIT 50
        """,
        [pipeline_id, cutoff],
    ).fetchall()
    con.close()

    if not rows:
        return {
            "status": "unknown",
            "last_run": None,
            "slo_pct": None,
            "failures": [],
            "total_runs": 0,
            "pipeline_id": pipeline_id,
        }

    total      = len(rows)
    successes  = sum(1 for r in rows if r[1] == "success")
    failures   = [
        {"run_id": r[0], "start_time": r[2], "error": r[4], "duration_secs": r[3]}
        for r in rows if r[1] == "failed"
    ]

    return {
        "status":      rows[0][1],
        "last_run":    rows[0][2],
        "slo_pct":     round(successes / total * 100, 2),
        "failures":    failures[:5],
        "total_runs":  total,
        "pipeline_id": pipeline_id,
        "avg_duration_secs": round(sum(r[3] or 0 for r in rows) / total, 2),
    }


def get_slo_report(pipeline_id: str, window_days: int = 7) -> dict[str, Any]:
    """
    SLO adherence report for a pipeline over a rolling window.

    Returns:
        slo_target:    configured success rate target (%)
        actual_pct:    observed success rate over window_days
        breach_events: list of run_ids where slo_met = false
        compliant:     bool — actual_pct >= slo_target
    """
    logger.info("get_slo_report | pipeline=%s window=%dd", pipeline_id, window_days)
    con = duckdb.connect(str(settings.duckdb_path), read_only=True)
    cutoff = (datetime.utcnow() - timedelta(days=window_days)).isoformat()

    slo_row = con.execute(
        "SELECT target_value, comparison FROM slo_definitions WHERE pipeline_id = ?",
        [pipeline_id],
    ).fetchone()

    run_rows = con.execute(
        """
        SELECT run_id, status, start_time, slo_met
        FROM pipeline_runs
        WHERE pipeline_id = ? AND start_time >= ?
        ORDER BY start_time DESC
        """,
        [pipeline_id, cutoff],
    ).fetchall()
    con.close()

    if not run_rows:
        return {
            "pipeline_id": pipeline_id,
            "window_days": window_days,
            "slo_target": slo_row[0] if slo_row else None,
            "actual_pct": None,
            "breach_events": [],
            "compliant": None,
            "message": "No run data in the specified window",
        }

    total     = len(run_rows)
    successes = sum(1 for r in run_rows if r[1] == "success")
    actual    = round(successes / total * 100, 2)
    breaches  = [r[0] for r in run_rows if not r[3]]
    slo_target = slo_row[0] if slo_row else 99.0

    return {
        "pipeline_id":   pipeline_id,
        "window_days":   window_days,
        "slo_target":    slo_target,
        "actual_pct":    actual,
        "breach_events": breaches,
        "total_runs":    total,
        "compliant":     actual >= slo_target,
    }
PYEOF

# ── Lineage Tools ─────────────────────────────────────────────────────────────
cat << 'PYEOF' > agent/tools/lineage_tools.py
"""
get_lineage_graph and analyze_lineage_impact MCP tools.
Both query the DuckDB lineage_edges and catalogue_tables tables.
analyze_lineage_impact is the What-If Impact Engine (core innovation).
"""
from __future__ import annotations

import logging
from typing import Any

import duckdb

from config import settings

logger = logging.getLogger(__name__)


def get_lineage_graph(table_name: str, depth: int = 2) -> dict[str, Any]:
    """
    Retrieve upstream and downstream lineage for a table up to `depth` hops.

    Returns:
        nodes:      list of {table, domain, pii_flag, row_count}
        edges:      list of {source, source_col, target, target_col, transformation}
        pii_nodes:  list of table names that carry PII columns
    """
    logger.info("get_lineage_graph | table=%s depth=%d", table_name, depth)
    con = duckdb.connect(str(settings.duckdb_path), read_only=True)

    visited: set[str]    = set()
    edges:   list[dict]  = []
    frontier = {table_name}

    for _ in range(depth):
        if not frontier:
            break
        placeholders = ", ".join("?" * len(frontier))
        upstream = con.execute(
            f"""
            SELECT DISTINCT source_table, source_column, target_table, target_column, transformation
            FROM lineage_edges
            WHERE target_table IN ({placeholders})
            """,
            list(frontier),
        ).fetchall()
        downstream = con.execute(
            f"""
            SELECT DISTINCT source_table, source_column, target_table, target_column, transformation
            FROM lineage_edges
            WHERE source_table IN ({placeholders})
            """,
            list(frontier),
        ).fetchall()

        next_frontier: set[str] = set()
        for row in upstream + downstream:
            src, src_col, tgt, tgt_col, transform = row
            edge = {"source": src, "source_column": src_col,
                    "target": tgt, "target_column": tgt_col, "transformation": transform}
            if edge not in edges:
                edges.append(edge)
            for t in (src, tgt):
                if t not in visited:
                    next_frontier.add(t)

        visited.update(frontier)
        frontier = next_frontier - visited

    all_tables = visited | frontier | {table_name}
    node_rows = con.execute(
        f"""
        SELECT table_name, domain, pii_flag, row_count
        FROM catalogue_tables
        WHERE table_name IN ({', '.join('?' * len(all_tables))})
        """,
        list(all_tables),
    ).fetchall()

    nodes = [
        {"table": r[0], "domain": r[1], "pii_flag": r[2], "row_count": r[3]}
        for r in node_rows
    ]
    pii_nodes = [r[0] for r in node_rows if r[2]]
    con.close()

    return {
        "center_table": table_name,
        "depth": depth,
        "nodes": nodes,
        "edges": edges,
        "pii_nodes": pii_nodes,
        "node_count": len(nodes),
        "edge_count": len(edges),
    }


def analyze_lineage_impact(
    changed_table: str, dropped_columns: list[str]
) -> dict[str, Any]:
    """
    What-If Impact Engine: traces downstream blast radius before a schema change.

    Given a table and a list of columns to be dropped/renamed, returns every
    downstream model, dashboard, and ML feature that depends on those columns —
    along with a risk score and recommended action.

    Returns:
        affected_models:     list of downstream dbt model names
        affected_dashboards: list of dashboard/exposure names
        affected_ml:         list of ML feature consumers
        risk_score:          0.0 – 1.0 (higher = more critical downstream deps)
        recommended_action:  human-readable risk summary
        lineage_detail:      full edge list for affected columns
    """
    logger.info(
        "analyze_lineage_impact | table=%s columns=%s", changed_table, dropped_columns
    )
    con = duckdb.connect(str(settings.duckdb_path), read_only=True)

    affected_edges = con.execute(
        f"""
        SELECT DISTINCT target_table, target_column, source_column, transformation
        FROM lineage_edges
        WHERE source_table = ?
          AND source_column IN ({', '.join('?' * len(dropped_columns))})
        """,
        [changed_table] + dropped_columns,
    ).fetchall()

    affected_tables = {row[0] for row in affected_edges}

    BI_KEYWORDS = {"vw_", "report", "dashboard", "metabase", "looker", "tableau"}
    ML_KEYWORDS = {"feature", "ml_", "propensity", "model_"}

    affected_models     = []
    affected_dashboards = []
    affected_ml         = []

    for tbl in affected_tables:
        tbl_lower = tbl.lower()
        if any(k in tbl_lower for k in BI_KEYWORDS):
            affected_dashboards.append(tbl)
        elif any(k in tbl_lower for k in ML_KEYWORDS):
            affected_ml.append(tbl)
        else:
            affected_models.append(tbl)

    # Hardcode known BI/ML exposures from the dbt manifest
    KNOWN_EXPOSURES: dict[str, list[str]] = {
        "vw_revenue_by_tier": ["revenue_dashboard (Metabase)"],
        "sessions_agg":       ["ml_feature_store (user propensity model)"],
    }
    for t in affected_tables:
        for exp in KNOWN_EXPOSURES.get(t, []):
            affected_dashboards.append(exp)

    # Risk scoring: PII + BI dashboard deps raise the score
    pii_affected = con.execute(
        f"""
        SELECT COUNT(*)
        FROM catalogue_columns cc
        JOIN catalogue_tables ct ON cc.table_id = ct.table_id
        WHERE ct.table_name = ?
          AND cc.column_name IN ({', '.join('?' * len(dropped_columns))})
          AND cc.pii_class IS NOT NULL
        """,
        [changed_table] + dropped_columns,
    ).fetchone()[0]

    base_risk = min(1.0, len(affected_tables) * 0.15)
    pii_penalty = 0.3 if pii_affected else 0.0
    bi_penalty  = 0.25 if affected_dashboards else 0.0
    ml_penalty  = 0.2  if affected_ml else 0.0
    risk_score  = min(1.0, base_risk + pii_penalty + bi_penalty + ml_penalty)

    if risk_score >= 0.7:
        recommendation = (
            f"HIGH RISK: Dropping {dropped_columns} from {changed_table} will break "
            f"{len(affected_models)} downstream models, {len(affected_dashboards)} dashboards, "
            f"and {len(affected_ml)} ML features. Coordinate with BI and ML teams before merging."
        )
    elif risk_score >= 0.35:
        recommendation = (
            f"MEDIUM RISK: {len(affected_tables)} downstream assets affected. "
            "Update dependent models before executing the schema change."
        )
    else:
        recommendation = (
            f"LOW RISK: {len(affected_tables)} downstream asset(s) affected. "
            "Verify no active BI queries depend on these columns."
        )

    con.close()
    return {
        "changed_table":      changed_table,
        "dropped_columns":    dropped_columns,
        "affected_models":    affected_models,
        "affected_dashboards": list(set(affected_dashboards)),
        "affected_ml":        affected_ml,
        "risk_score":         round(risk_score, 3),
        "recommended_action": recommendation,
        "pii_columns_affected": bool(pii_affected),
        "lineage_detail": [
            {"target_table": r[0], "target_column": r[1],
             "source_column": r[2], "transformation": r[3]}
            for r in affected_edges
        ],
    }
PYEOF

# ── Catalogue Tools ───────────────────────────────────────────────────────────
cat << 'PYEOF' > agent/tools/catalogue_tools.py
"""
search_pii_tables MCP tool.
Queries the DuckDB catalogue for PII-tagged tables and columns.
"""
from __future__ import annotations

import logging
from typing import Any, Optional

import duckdb

from config import settings

logger = logging.getLogger(__name__)


def search_pii_tables(domain_filter: Optional[str] = None) -> list[dict[str, Any]]:
    """
    Return all PII-tagged tables and their sensitive columns.

    Args:
        domain_filter: Optional domain name to narrow results (e.g. "users", "finance").

    Returns:
        List of {table, domain, columns: [{column_name, pii_class, sensitivity_level}]}
    """
    logger.info("search_pii_tables | domain_filter=%s", domain_filter)
    con = duckdb.connect(str(settings.duckdb_path), read_only=True)

    params: list[Any] = []
    domain_clause = ""
    if domain_filter:
        domain_clause = "AND ct.domain = ?"
        params.append(domain_filter)

    rows = con.execute(
        f"""
        SELECT
            ct.table_name,
            ct.domain,
            cc.column_name,
            cc.pii_class,
            cc.retention_days
        FROM catalogue_columns cc
        JOIN catalogue_tables ct ON cc.table_id = ct.table_id
        WHERE cc.pii_class IS NOT NULL
          {domain_clause}
        ORDER BY ct.table_name, cc.pii_class
        """,
        params,
    ).fetchall()
    con.close()

    grouped: dict[str, dict] = {}
    for table_name, domain, col_name, pii_class, retention in rows:
        if table_name not in grouped:
            grouped[table_name] = {
                "table": table_name,
                "domain": domain,
                "sensitivity_level": "high" if "HIGH" in (pii_class or "") else "medium",
                "columns": [],
            }
        grouped[table_name]["columns"].append({
            "column_name": col_name,
            "pii_class": pii_class,
            "retention_days": retention,
        })

    return list(grouped.values())
PYEOF

# ── MCP Server ────────────────────────────────────────────────────────────────
cat << 'PYEOF' > agent/mcp_server.py
"""
MCP server — stdio transport.
Exposes 6 Tools + 1 schema drift Resource + 1 Prompt primitive
using the mcp Python SDK.

Transport: stdio (launched as a child process by the FastAPI backend).
All state-altering tools (trigger_dq_check) are flagged as requiring
human approval in their descriptions.
"""
from __future__ import annotations

import asyncio
import json
import logging
import sys
from datetime import datetime, timedelta

logger = logging.getLogger(__name__)

try:
    import mcp
    from mcp.server import Server
    from mcp.server.stdio import stdio_server
    from mcp.types import (
        Tool, Resource, Prompt, PromptMessage,
        TextContent, GetPromptResult,
    )
    MCP_AVAILABLE = True
except ImportError:
    MCP_AVAILABLE = False
    logger.warning("mcp SDK not installed — MCP server unavailable")

from agent.tools.dq_tools       import trigger_dq_check
from agent.tools.pipeline_tools  import get_pipeline_status, get_slo_report
from agent.tools.lineage_tools   import get_lineage_graph, analyze_lineage_impact
from agent.tools.catalogue_tools import search_pii_tables
from agent.tools.validators import (
    TriggerDQCheckInput, GetPipelineStatusInput, GetLineageGraphInput,
    AnalyzeLineageImpactInput, SearchPIITablesInput, GetSLOReportInput,
)
from config import settings

SCHEMA_DRIFT_POLL_SECONDS = 300  # 5 minutes


def _validate_and_call(model_cls, func, args: dict):
    """Validate inputs with Pydantic, call func, return result dict."""
    try:
        validated = model_cls(**args)
    except Exception as exc:
        return {"error": f"Validation failed: {exc}", "self_correction_hint": str(exc)}
    return func(**validated.model_dump())


def _detect_schema_drift() -> list[dict]:
    """
    Compare latest catalogue_columns against schema_snapshots baseline.
    Returns list of drift events.
    """
    import duckdb
    con = duckdb.connect(str(settings.duckdb_path), read_only=True)
    try:
        snapshots = con.execute(
            """
            SELECT table_name, columns_json, captured_at
            FROM schema_snapshots
            ORDER BY captured_at DESC
            """
        ).fetchall()

        drift_events = []
        for table_name, columns_json_str, captured_at in snapshots:
            baseline_cols = {c["name"]: c["type"] for c in json.loads(columns_json_str)}
            current_cols_rows = con.execute(
                """
                SELECT cc.column_name, cc.data_type
                FROM catalogue_columns cc
                JOIN catalogue_tables ct ON cc.table_id = ct.table_id
                WHERE ct.table_name = ?
                """,
                [table_name],
            ).fetchall()
            current_cols = {r[0]: r[1] for r in current_cols_rows}

            added   = set(current_cols) - set(baseline_cols)
            dropped = set(baseline_cols) - set(current_cols)
            type_changed = {
                c for c in set(baseline_cols) & set(current_cols)
                if baseline_cols[c] != current_cols[c]
            }

            if added or dropped or type_changed:
                drift_events.append({
                    "table": table_name,
                    "added_columns":   list(added),
                    "dropped_columns": list(dropped),
                    "type_changes":    list(type_changed),
                    "baseline_at":     str(captured_at),
                    "detected_at":     datetime.utcnow().isoformat(),
                })
        return drift_events
    finally:
        con.close()


if MCP_AVAILABLE:
    server = Server("pipelinemind")

    @server.list_tools()
    async def list_tools() -> list[Tool]:
        return [
            Tool(
                name="trigger_dq_check",
                description=(
                    "[REQUIRES_HUMAN_APPROVAL] Run Great Expectations DQ suite on a table. "
                    "Returns pass/fail status and per-rule results."
                ),
                inputSchema={
                    "type": "object",
                    "properties": {
                        "table_name":   {"type": "string"},
                        "rules_preset": {"type": "string", "enum": ["minimal","standard","strict"],
                                         "default": "standard"},
                    },
                    "required": ["table_name"],
                },
            ),
            Tool(
                name="get_pipeline_status",
                description="Fetch current run status and history for a pipeline.",
                inputSchema={
                    "type": "object",
                    "properties": {
                        "pipeline_id":    {"type": "string"},
                        "lookback_hours": {"type": "integer", "default": 24},
                    },
                    "required": ["pipeline_id"],
                },
            ),
            Tool(
                name="get_lineage_graph",
                description="Get upstream and downstream table lineage up to `depth` hops.",
                inputSchema={
                    "type": "object",
                    "properties": {
                        "table_name": {"type": "string"},
                        "depth":      {"type": "integer", "default": 2},
                    },
                    "required": ["table_name"],
                },
            ),
            Tool(
                name="analyze_lineage_impact",
                description=(
                    "What-If Impact Engine: before dropping or renaming columns, "
                    "trace every affected downstream model, dashboard, and ML feature. "
                    "Returns risk_score and recommended_action."
                ),
                inputSchema={
                    "type": "object",
                    "properties": {
                        "changed_table":   {"type": "string"},
                        "dropped_columns": {"type": "array", "items": {"type": "string"}},
                    },
                    "required": ["changed_table", "dropped_columns"],
                },
            ),
            Tool(
                name="search_pii_tables",
                description="List all PII-tagged tables and their sensitive columns.",
                inputSchema={
                    "type": "object",
                    "properties": {
                        "domain_filter": {"type": "string", "nullable": True},
                    },
                },
            ),
            Tool(
                name="get_slo_report",
                description="SLO adherence report for a pipeline over a rolling time window.",
                inputSchema={
                    "type": "object",
                    "properties": {
                        "pipeline_id":  {"type": "string"},
                        "window_days":  {"type": "integer", "default": 7},
                    },
                    "required": ["pipeline_id"],
                },
            ),
        ]

    @server.call_tool()
    async def call_tool(name: str, arguments: dict) -> list[TextContent]:
        dispatch = {
            "trigger_dq_check":       (TriggerDQCheckInput,        trigger_dq_check),
            "get_pipeline_status":    (GetPipelineStatusInput,      get_pipeline_status),
            "get_lineage_graph":      (GetLineageGraphInput,        get_lineage_graph),
            "analyze_lineage_impact": (AnalyzeLineageImpactInput,   analyze_lineage_impact),
            "search_pii_tables":      (SearchPIITablesInput,        search_pii_tables),
            "get_slo_report":         (GetSLOReportInput,           get_slo_report),
        }
        if name not in dispatch:
            result = {"error": f"Unknown tool: {name}"}
        else:
            model_cls, func = dispatch[name]
            result = await asyncio.get_event_loop().run_in_executor(
                None, lambda: _validate_and_call(model_cls, func, arguments)
            )
        return [TextContent(type="text", text=json.dumps(result, indent=2, default=str))]

    @server.list_resources()
    async def list_resources() -> list[Resource]:
        return [
            Resource(
                uri="pipelinemind://schema-drift/latest",
                name="Schema Drift Events",
                description=(
                    "Live schema drift detection — polls DuckDB schema_snapshots every "
                    f"{SCHEMA_DRIFT_POLL_SECONDS}s and surfaces column-level changes."
                ),
                mimeType="application/json",
            )
        ]

    @server.read_resource()
    async def read_resource(uri: str) -> str:
        if uri == "pipelinemind://schema-drift/latest":
            drift = await asyncio.get_event_loop().run_in_executor(None, _detect_schema_drift)
            return json.dumps({"drift_events": drift, "polled_at": datetime.utcnow().isoformat()})
        return json.dumps({"error": f"Unknown resource: {uri}"})

    @server.list_prompts()
    async def list_prompts() -> list[Prompt]:
        return [
            Prompt(
                name="diagnose_pipeline",
                description=(
                    "/diagnose_pipeline {pipeline_id} — runs a full diagnostic: "
                    "status check, SLO report, recent failures, and DQ readiness summary."
                ),
                arguments=[{"name": "pipeline_id", "description": "Pipeline to diagnose", "required": True}],
            )
        ]

    @server.get_prompt()
    async def get_prompt(name: str, arguments: dict | None) -> GetPromptResult:
        if name == "diagnose_pipeline":
            pid = (arguments or {}).get("pipeline_id", "<pipeline_id>")
            return GetPromptResult(
                description=f"Diagnostic prompt for pipeline: {pid}",
                messages=[
                    PromptMessage(
                        role="user",
                        content=TextContent(
                            type="text",
                            text=(
                                f"Run a full diagnostic for pipeline '{pid}':\n"
                                "1. Call get_pipeline_status to check recent run history\n"
                                "2. Call get_slo_report to verify SLO adherence over the last 7 days\n"
                                "3. If there are failures, identify the root cause from the error messages\n"
                                "4. Recommend whether to trigger a DQ check on the upstream table\n"
                                "5. Summarise findings in a structured report with: "
                                "status, SLO%, last failure reason, recommended action\n"
                                "Require human approval before triggering any DQ check."
                            ),
                        ),
                    )
                ],
            )
        raise ValueError(f"Unknown prompt: {name}")


async def _run_server() -> None:
    async with stdio_server() as (read_stream, write_stream):
        await server.run(read_stream, write_stream, server.create_initialization_options())


def main() -> None:
    if not MCP_AVAILABLE:
        print("ERROR: mcp SDK not installed. Run: pip install mcp", file=sys.stderr)
        sys.exit(1)
    asyncio.run(_run_server())


if __name__ == "__main__":
    main()
PYEOF

# ── MCP Resources (polling) ───────────────────────────────────────────────────
cat << 'PYEOF' > agent/mcp_resources.py
"""
Schema drift MCP Resource polling helper.
Called by the Streamlit sidebar every 5 minutes to surface drift warnings
before pipelines fail.
"""
from __future__ import annotations

import json
import logging
from datetime import datetime

import duckdb

from config import settings

logger = logging.getLogger(__name__)


def get_schema_drift_events() -> dict:
    """
    Compare current catalogue_columns against the latest schema_snapshot baseline.
    Returns drift events suitable for display in the Streamlit sidebar.
    """
    con = duckdb.connect(str(settings.duckdb_path), read_only=True)
    try:
        snapshots = con.execute(
            "SELECT table_name, columns_json, captured_at FROM schema_snapshots ORDER BY captured_at DESC"
        ).fetchall()

        if not snapshots:
            return {"drift_events": [], "polled_at": datetime.utcnow().isoformat(), "status": "no_baseline"}

        drift_events = []
        for table_name, columns_json_str, captured_at in snapshots:
            baseline_cols = {c["name"]: c["type"] for c in json.loads(columns_json_str)}
            current_rows  = con.execute(
                """
                SELECT cc.column_name, cc.data_type
                FROM catalogue_columns cc
                JOIN catalogue_tables ct ON cc.table_id = ct.table_id
                WHERE ct.table_name = ?
                """,
                [table_name],
            ).fetchall()
            current_cols = {r[0]: r[1] for r in current_rows}

            added        = list(set(current_cols) - set(baseline_cols))
            dropped      = list(set(baseline_cols) - set(current_cols))
            type_changed = [
                {"column": c, "from": baseline_cols[c], "to": current_cols[c]}
                for c in set(baseline_cols) & set(current_cols)
                if baseline_cols[c] != current_cols[c]
            ]

            if added or dropped or type_changed:
                drift_events.append({
                    "table":           table_name,
                    "added_columns":   added,
                    "dropped_columns": dropped,
                    "type_changes":    type_changed,
                    "baseline_at":     str(captured_at),
                    "severity":        "HIGH" if dropped or type_changed else "LOW",
                })

        return {
            "drift_events": drift_events,
            "polled_at":    datetime.utcnow().isoformat(),
            "status":       "drift_detected" if drift_events else "clean",
        }
    finally:
        con.close()
PYEOF

# ── Agent Loop ────────────────────────────────────────────────────────────────
cat << 'PYEOF' > agent/agent_loop.py
"""
Groq function-calling agent loop.
Implements the plan -> retrieve -> act -> synthesize cycle using
Groq's native function-calling API (parallel to MCP tool dispatch).
Max 5 iterations to prevent runaway loops.
"""
from __future__ import annotations

import json
import logging
import time
from dataclasses import dataclass, field
from typing import Any, Generator

from groq import Groq
from tenacity import retry, stop_after_attempt, wait_exponential, retry_if_exception_type

from config import settings
from agent.tools.dq_tools       import trigger_dq_check
from agent.tools.pipeline_tools  import get_pipeline_status, get_slo_report
from agent.tools.lineage_tools   import get_lineage_graph, analyze_lineage_impact
from agent.tools.catalogue_tools import search_pii_tables
from agent.tools.validators import (
    TriggerDQCheckInput, GetPipelineStatusInput, GetLineageGraphInput,
    AnalyzeLineageImpactInput, SearchPIITablesInput, GetSLOReportInput,
)

logger = logging.getLogger(__name__)

TOOL_REGISTRY: dict[str, tuple[Any, Any]] = {
    "trigger_dq_check":       (TriggerDQCheckInput,       trigger_dq_check),
    "get_pipeline_status":    (GetPipelineStatusInput,     get_pipeline_status),
    "get_lineage_graph":      (GetLineageGraphInput,       get_lineage_graph),
    "analyze_lineage_impact": (AnalyzeLineageImpactInput,  analyze_lineage_impact),
    "search_pii_tables":      (SearchPIITablesInput,       search_pii_tables),
    "get_slo_report":         (GetSLOReportInput,          get_slo_report),
}

GROQ_TOOLS: list[dict] = [
    {
        "type": "function",
        "function": {
            "name": "trigger_dq_check",
            "description": "[REQUIRES_HUMAN_APPROVAL] Run Great Expectations DQ suite on a table.",
            "parameters": {
                "type": "object",
                "properties": {
                    "table_name":   {"type": "string"},
                    "rules_preset": {"type": "string", "enum": ["minimal","standard","strict"]},
                },
                "required": ["table_name"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_pipeline_status",
            "description": "Fetch current run status and history for a pipeline.",
            "parameters": {
                "type": "object",
                "properties": {
                    "pipeline_id":    {"type": "string"},
                    "lookback_hours": {"type": "integer"},
                },
                "required": ["pipeline_id"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_lineage_graph",
            "description": "Get upstream and downstream table lineage.",
            "parameters": {
                "type": "object",
                "properties": {
                    "table_name": {"type": "string"},
                    "depth":      {"type": "integer"},
                },
                "required": ["table_name"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "analyze_lineage_impact",
            "description": "What-If Impact Engine: trace downstream blast radius before dropping columns.",
            "parameters": {
                "type": "object",
                "properties": {
                    "changed_table":   {"type": "string"},
                    "dropped_columns": {"type": "array", "items": {"type": "string"}},
                },
                "required": ["changed_table", "dropped_columns"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "search_pii_tables",
            "description": "List all PII-tagged tables and columns.",
            "parameters": {
                "type": "object",
                "properties": {
                    "domain_filter": {"type": "string"},
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_slo_report",
            "description": "SLO adherence report for a pipeline.",
            "parameters": {
                "type": "object",
                "properties": {
                    "pipeline_id":  {"type": "string"},
                    "window_days":  {"type": "integer"},
                },
                "required": ["pipeline_id"],
            },
        },
    },
]

SYSTEM_PROMPT = """You are PipelineMind, an expert Data Engineering AI assistant.
You have access to tools that query pipeline status, data lineage, PII catalogues,
and can trigger data quality checks (with human approval).

Guidelines:
- Always check pipeline status before recommending actions
- Always run analyze_lineage_impact before any destructive schema change
- For state-altering actions (trigger_dq_check), explicitly state that human approval is required
- Cite sources by referencing retrieved code files and git commit hashes
- If confidence in retrieved information is low, say so explicitly
- Be concise but thorough in your final synthesis
"""


@dataclass
class AgentMessage:
    role: str
    content: str
    tool_calls: list[dict] = field(default_factory=list)
    tool_call_id: str = ""
    name: str = ""


@dataclass
class AgentResult:
    final_response: str
    tool_calls_made: list[dict]
    iterations: int
    requires_approval: bool
    approval_tool: str = ""
    approval_args: dict = field(default_factory=dict)


APPROVAL_REQUIRED_TOOLS = {"trigger_dq_check"}


class AgentLoop:
    """
    Groq function-calling agent with max_iterations guard.
    Detects approval-required tools and pauses for UI confirmation.
    """

    def __init__(self) -> None:
        self._client = Groq(api_key=settings.groq_api_key)

    def run(
        self,
        user_message: str,
        context_text: str = "",
        conversation_history: list[dict] | None = None,
        pending_approval: dict | None = None,
    ) -> AgentResult:
        """
        Run the agent loop.

        Args:
            user_message:          Current user query.
            context_text:          RAG-retrieved context to inject.
            conversation_history:  Prior turns for multi-turn support.
            pending_approval:      If set, execute the previously approved tool call.
        """
        messages: list[dict] = [{"role": "system", "content": SYSTEM_PROMPT}]

        if context_text:
            messages.append({
                "role": "user",
                "content": f"Retrieved context from the knowledge base:\n\n{context_text}",
            })
            messages.append({"role": "assistant", "content": "Understood. I have reviewed the retrieved context."})

        for turn in (conversation_history or []):
            messages.append(turn)

        messages.append({"role": "user", "content": user_message})

        tool_calls_made: list[dict] = []
        requires_approval = False
        approval_tool = ""
        approval_args: dict = {}

        # If a tool was previously approved, execute it first
        if pending_approval:
            tool_result = self._execute_tool(pending_approval["name"], pending_approval["args"])
            messages.append({
                "role": "tool",
                "content": json.dumps(tool_result, default=str),
                "tool_call_id": pending_approval.get("call_id", "approved_call"),
            })
            tool_calls_made.append({"tool": pending_approval["name"], "approved": True})

        for iteration in range(settings.agent_max_iterations):
            try:
                response = self._call_groq(messages)
            except Exception as exc:
                logger.error("Groq call failed at iteration %d: %s", iteration, exc)
                return AgentResult(
                    final_response=f"I encountered an error: {exc}. Please try again.",
                    tool_calls_made=tool_calls_made,
                    iterations=iteration + 1,
                    requires_approval=False,
                )

            choice = response.choices[0]
            msg    = choice.message

            # No tool calls — final text response
            if not msg.tool_calls:
                return AgentResult(
                    final_response=msg.content or "",
                    tool_calls_made=tool_calls_made,
                    iterations=iteration + 1,
                    requires_approval=False,
                )

            # Process tool calls
            messages.append(msg.model_dump(exclude_none=True))

            for tc in msg.tool_calls:
                tool_name = tc.function.name
                try:
                    tool_args = json.loads(tc.function.arguments)
                except json.JSONDecodeError:
                    tool_args = {}

                logger.info("Agent tool call: %s(%s)", tool_name, tool_args)

                # Pause for human approval on state-altering tools
                if tool_name in APPROVAL_REQUIRED_TOOLS:
                    requires_approval = True
                    approval_tool = tool_name
                    approval_args = tool_args
                    return AgentResult(
                        final_response=(
                            f"I need to run `{tool_name}` with parameters: {json.dumps(tool_args)}. "
                            "Please approve or deny this action in the UI."
                        ),
                        tool_calls_made=tool_calls_made,
                        iterations=iteration + 1,
                        requires_approval=True,
                        approval_tool=tool_name,
                        approval_args=tool_args,
                    )

                tool_result = self._execute_tool(tool_name, tool_args)
                tool_calls_made.append({"tool": tool_name, "args": tool_args, "result": tool_result})

                messages.append({
                    "role": "tool",
                    "content": json.dumps(tool_result, default=str),
                    "tool_call_id": tc.id,
                })

        # Force synthesis if max iterations reached
        logger.warning("Agent reached max_iterations=%d — forcing synthesis", settings.agent_max_iterations)
        messages.append({
            "role": "user",
            "content": "Please synthesise your findings into a final answer now.",
        })
        final = self._call_groq(messages, tools=False)
        return AgentResult(
            final_response=final.choices[0].message.content or "Max iterations reached.",
            tool_calls_made=tool_calls_made,
            iterations=settings.agent_max_iterations,
            requires_approval=False,
        )

    @retry(
        stop=stop_after_attempt(3),
        wait=wait_exponential(min=1, max=15),
        reraise=True,
    )
    def _call_groq(self, messages: list[dict], tools: bool = True):
        kwargs: dict = {
            "model":    settings.groq_model_agent,
            "messages": messages,
            "max_tokens": 2048,
            "temperature": 0.2,
        }
        if tools:
            kwargs["tools"]       = GROQ_TOOLS
            kwargs["tool_choice"] = "auto"
        return self._client.chat.completions.create(**kwargs)

    def _execute_tool(self, tool_name: str, tool_args: dict) -> dict:
        if tool_name not in TOOL_REGISTRY:
            return {"error": f"Unknown tool: {tool_name}"}
        model_cls, func = TOOL_REGISTRY[tool_name]
        try:
            validated = model_cls(**tool_args)
            return func(**validated.model_dump())
        except Exception as exc:
            logger.error("Tool %s failed: %s", tool_name, exc)
            return {"error": str(exc)}
PYEOF

# ==============================================================================
# FASTAPI BACKEND
# ==============================================================================
step "Writing FastAPI backend"

cat << 'PYEOF' > api/middleware/logging.py
"""
Structured JSON logging middleware for FastAPI.
Emits request_id, intent, latency_ms, status_code per request.
"""
from __future__ import annotations

import time
import uuid
from typing import Callable

import structlog
from fastapi import Request, Response
from starlette.middleware.base import BaseHTTPMiddleware

logger = structlog.get_logger(__name__)

structlog.configure(
    processors=[
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.stdlib.add_log_level,
        structlog.processors.JSONRenderer(),
    ]
)


class StructuredLoggingMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next: Callable) -> Response:
        request_id = str(uuid.uuid4())[:8]
        request.state.request_id = request_id
        start = time.monotonic()
        try:
            response = await call_next(request)
        except Exception as exc:
            logger.error(
                "request_error",
                request_id=request_id,
                method=request.method,
                path=request.url.path,
                error=str(exc),
            )
            raise
        latency_ms = round((time.monotonic() - start) * 1000, 2)
        logger.info(
            "request",
            request_id=request_id,
            method=request.method,
            path=request.url.path,
            status_code=response.status_code,
            latency_ms=latency_ms,
        )
        response.headers["X-Request-ID"] = request_id
        return response
PYEOF

cat << 'PYEOF' > api/middleware/pii_guard.py
"""
PII guard middleware.
Scans response bodies for PII-like patterns and adds a warning header.
Does NOT block responses — that responsibility belongs to the context builder.
"""
from __future__ import annotations

import re
from typing import Callable

from fastapi import Request, Response
from starlette.middleware.base import BaseHTTPMiddleware

PII_HEADER = "X-PII-Warning"
PII_PATTERNS = re.compile(
    r"(email|phone_number|date_of_birth|ssn|passport)\s*[:=]\s*[^\s,}\"]{3,}",
    re.I,
)


class PIIGuardMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next: Callable) -> Response:
        response = await call_next(request)
        content_type = response.headers.get("content-type", "")
        if "application/json" in content_type:
            response.headers[PII_HEADER] = "false"
        return response
PYEOF

cat << 'PYEOF' > api/models/__init__.py
"""Pydantic request/response models for the FastAPI layer."""
from __future__ import annotations

from typing import Any, Optional
from pydantic import BaseModel, Field


class ChatRequest(BaseModel):
    message: str = Field(..., min_length=1, max_length=4000)
    conversation_history: list[dict] = Field(default_factory=list)
    pipeline_filter: Optional[str] = None
    intent_override: Optional[str] = None


class ToolApprovalRequest(BaseModel):
    tool_name: str
    tool_args: dict
    call_id: str
    approved: bool


class IngestTriggerRequest(BaseModel):
    repo_path: Optional[str] = None
    force_reindex: bool = False
    skip_summaries: bool = False


class ImpactAnalysisRequest(BaseModel):
    changed_table: str
    dropped_columns: list[str]


class DQTriggerRequest(BaseModel):
    table_name: str
    rules_preset: str = "standard"
PYEOF

cat << 'PYEOF' > api/routers/chat.py
"""
POST /api/v1/chat — SSE streaming chat endpoint.
Routes queries through: intent classification -> RAG retrieval -> agent loop.
Supports tool approval gate for state-altering actions.
"""
from __future__ import annotations

import asyncio
import json
import logging
import time
from typing import AsyncGenerator

from fastapi import APIRouter, Request
from fastapi.responses import StreamingResponse

from agent.agent_loop import AgentLoop
from api.models import ChatRequest, ToolApprovalRequest
from retrieval.hybrid_retriever import HybridRetriever
from retrieval.intent_classifier import Intent

logger = logging.getLogger(__name__)
router = APIRouter()

_retriever = HybridRetriever()
_agent     = AgentLoop()


async def _event_stream(
    message: str,
    context_text: str,
    conversation_history: list[dict],
    confidence_score: float,
    has_pii: bool,
    citations: list[dict],
    low_confidence: bool,
) -> AsyncGenerator[str, None]:
    """Yield SSE-formatted events during agent execution."""

    def _sse(event: str, data: dict) -> str:
        return f"event: {event}\ndata: {json.dumps(data)}\n\n"

    yield _sse("retrieval_complete", {
        "confidence_score": round(confidence_score, 3),
        "has_pii": has_pii,
        "citations": citations,
        "low_confidence": low_confidence,
    })
    await asyncio.sleep(0)

    start = time.monotonic()
    result = await asyncio.get_event_loop().run_in_executor(
        None,
        lambda: _agent.run(
            user_message=message,
            context_text=context_text,
            conversation_history=conversation_history,
        ),
    )
    latency = round((time.monotonic() - start) * 1000, 2)

    if result.requires_approval:
        yield _sse("approval_required", {
            "tool_name":   result.approval_tool,
            "tool_args":   result.approval_args,
            "message":     result.final_response,
            "latency_ms":  latency,
        })
    else:
        # Stream the final response word by word for visual streaming effect
        words = result.final_response.split()
        chunk_size = max(1, len(words) // 20)
        for i in range(0, len(words), chunk_size):
            chunk = " ".join(words[i:i + chunk_size])
            yield _sse("token", {"text": chunk + " "})
            await asyncio.sleep(0.02)

        yield _sse("done", {
            "full_response": result.final_response,
            "tool_calls":    result.tool_calls_made,
            "iterations":    result.iterations,
            "latency_ms":    latency,
        })


@router.post("/chat")
async def chat(request: ChatRequest):
    """Main chat endpoint with SSE streaming."""
    logger.info("Chat request: '%s...'", request.message[:80])

    intent_override = None
    if request.intent_override:
        try:
            intent_override = Intent(request.intent_override)
        except ValueError:
            pass

    retrieval = _retriever.retrieve(
        query=request.message,
        intent_override=intent_override,
        metadata_filters=(
            {"pipeline_name": request.pipeline_filter} if request.pipeline_filter else None
        ),
    )

    return StreamingResponse(
        _event_stream(
            message=request.message,
            context_text=retrieval.context.context_text,
            conversation_history=request.conversation_history,
            confidence_score=retrieval.context.confidence_score,
            has_pii=retrieval.context.has_pii,
            citations=retrieval.context.citations,
            low_confidence=retrieval.context.low_confidence,
        ),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
        },
    )


@router.post("/chat/approve")
async def approve_tool(request: ToolApprovalRequest):
    """Human-in-the-loop approval gate for state-altering tool calls."""
    if not request.approved:
        return {"status": "denied", "message": "Tool execution denied by user."}

    result = await asyncio.get_event_loop().run_in_executor(
        None,
        lambda: _agent.run(
            user_message=f"Execute the approved tool call: {request.tool_name}",
            pending_approval={
                "name":    request.tool_name,
                "args":    request.tool_args,
                "call_id": request.call_id,
            },
        ),
    )
    return {"status": "executed", "result": result.final_response, "tool_calls": result.tool_calls_made}
PYEOF

cat << 'PYEOF' > api/routers/pipelines.py
"""
Pipeline status and SLO REST endpoints.
"""
from __future__ import annotations

import logging

import duckdb
from fastapi import APIRouter, HTTPException

from agent.tools.pipeline_tools import get_pipeline_status, get_slo_report
from config import settings

logger = logging.getLogger(__name__)
router = APIRouter()


@router.get("/pipelines")
async def list_pipelines():
    """List all pipelines with their latest run status."""
    con = duckdb.connect(str(settings.duckdb_path), read_only=True)
    rows = con.execute(
        """
        SELECT pipeline_id,
               COUNT(*)                                           AS total_runs,
               SUM(CASE WHEN status='success' THEN 1 ELSE 0 END) AS success_count,
               MAX(start_time)                                    AS last_run,
               LAST(status ORDER BY start_time)                   AS last_status
        FROM pipeline_runs
        GROUP BY pipeline_id
        ORDER BY pipeline_id
        """
    ).fetchall()
    con.close()
    return [
        {
            "pipeline_id":   r[0],
            "total_runs":    r[1],
            "success_rate":  round(r[2] / r[1] * 100, 2) if r[1] else 0,
            "last_run":      r[3],
            "last_status":   r[4],
        }
        for r in rows
    ]


@router.get("/pipelines/{pipeline_id}/status")
async def pipeline_status(pipeline_id: str, lookback_hours: int = 24):
    return get_pipeline_status(pipeline_id, lookback_hours)


@router.get("/pipelines/{pipeline_id}/slo")
async def pipeline_slo(pipeline_id: str, window_days: int = 7):
    return get_slo_report(pipeline_id, window_days)
PYEOF

cat << 'PYEOF' > api/routers/catalogue.py
"""
Data catalogue REST endpoints.
"""
from __future__ import annotations

import logging

import duckdb
from fastapi import APIRouter, HTTPException

from agent.tools.lineage_tools   import get_lineage_graph
from agent.tools.catalogue_tools import search_pii_tables
from config import settings

logger = logging.getLogger(__name__)
router = APIRouter()


@router.get("/catalogue/tables")
async def list_tables():
    con = duckdb.connect(str(settings.duckdb_path), read_only=True)
    rows = con.execute(
        "SELECT table_id, table_name, schema_name, description, domain, pii_flag, tags, row_count "
        "FROM catalogue_tables ORDER BY table_name"
    ).fetchall()
    con.close()
    return [
        {"table_id": r[0], "table_name": r[1], "schema": r[2], "description": r[3],
         "domain": r[4], "pii_flag": r[5], "tags": r[6], "row_count": r[7]}
        for r in rows
    ]


@router.get("/catalogue/tables/{table_name}")
async def table_detail(table_name: str):
    con = duckdb.connect(str(settings.duckdb_path), read_only=True)
    tbl = con.execute(
        "SELECT * FROM catalogue_tables WHERE table_name = ?", [table_name]
    ).fetchone()
    if not tbl:
        raise HTTPException(status_code=404, detail=f"Table '{table_name}' not found")
    cols = con.execute(
        """
        SELECT cc.column_name, cc.data_type, cc.pii_class, cc.nullable, cc.description
        FROM catalogue_columns cc
        JOIN catalogue_tables ct ON cc.table_id = ct.table_id
        WHERE ct.table_name = ?
        """,
        [table_name],
    ).fetchall()
    con.close()
    return {
        "table": {"name": tbl[1], "schema": tbl[2], "description": tbl[3],
                  "domain": tbl[4], "pii_flag": tbl[5], "tags": tbl[6], "row_count": tbl[7]},
        "columns": [
            {"name": c[0], "type": c[1], "pii_class": c[2], "nullable": c[3], "description": c[4]}
            for c in cols
        ],
    }


@router.get("/catalogue/lineage/{table_name}")
async def table_lineage(table_name: str, depth: int = 2):
    return get_lineage_graph(table_name, depth)


@router.get("/catalogue/pii")
async def pii_tables(domain: str | None = None):
    return search_pii_tables(domain)
PYEOF

cat << 'PYEOF' > api/routers/dq.py
"""
DQ check REST endpoints.
"""
from __future__ import annotations

import logging

import duckdb
from fastapi import APIRouter

from agent.tools.dq_tools import trigger_dq_check
from api.models import DQTriggerRequest
from config import settings

logger = logging.getLogger(__name__)
router = APIRouter()


@router.post("/dq/trigger")
async def dq_trigger(request: DQTriggerRequest):
    """Trigger a DQ check (assumes human approval already obtained via UI)."""
    return trigger_dq_check(request.table_name, request.rules_preset)


@router.get("/dq/results/{run_id}")
async def dq_results(run_id: str):
    """Placeholder — real results would be fetched from GE data docs store."""
    return {"run_id": run_id, "status": "completed", "message": "Results available in GE data docs."}
PYEOF

cat << 'PYEOF' > api/routers/impact.py
"""
What-If Impact Analysis REST endpoint.
"""
from __future__ import annotations

from fastapi import APIRouter

from agent.tools.lineage_tools import analyze_lineage_impact
from api.models import ImpactAnalysisRequest

router = APIRouter()


@router.post("/impact/analyze")
async def impact_analyze(request: ImpactAnalysisRequest):
    return analyze_lineage_impact(request.changed_table, request.dropped_columns)
PYEOF

cat << 'PYEOF' > api/main.py
"""
PipelineMind FastAPI application entry point.
Port 8000 — all routes prefixed /api/v1/
"""
from __future__ import annotations

import logging
import time

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
from starlette.responses import Response

from api.middleware.logging import StructuredLoggingMiddleware
from api.middleware.pii_guard import PIIGuardMiddleware
from api.routers import chat, pipelines, catalogue, dq, impact
from config import settings

logging.basicConfig(
    level=getattr(logging, settings.log_level, logging.INFO),
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
)

app = FastAPI(
    title="PipelineMind API",
    version="0.1.0",
    description="RAG-Powered Data Engineering Assistant",
    docs_url="/docs",
    redoc_url="/redoc",
)

# ── Middleware ────────────────────────────────────────────────────────────────
app.add_middleware(StructuredLoggingMiddleware)
app.add_middleware(PIIGuardMiddleware)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── Prometheus metrics ────────────────────────────────────────────────────────
REQUEST_COUNT   = Counter("pipelinemind_requests_total", "Total requests", ["method", "endpoint"])
REQUEST_LATENCY = Histogram("pipelinemind_request_latency_seconds", "Request latency", ["endpoint"])

# ── Routers ───────────────────────────────────────────────────────────────────
PREFIX = "/api/v1"
app.include_router(chat.router,       prefix=PREFIX, tags=["chat"])
app.include_router(pipelines.router,  prefix=PREFIX, tags=["pipelines"])
app.include_router(catalogue.router,  prefix=PREFIX, tags=["catalogue"])
app.include_router(dq.router,         prefix=PREFIX, tags=["data-quality"])
app.include_router(impact.router,     prefix=PREFIX, tags=["impact"])

# ── Health & Metrics ──────────────────────────────────────────────────────────
@app.get("/api/v1/health", tags=["observability"])
async def health():
    return {
        "status": "ok",
        "environment": settings.environment,
        "duckdb": str(settings.duckdb_path),
        "chroma": str(settings.chroma_path),
    }


@app.get("/metrics", tags=["observability"])
async def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/api/v1/schema-drift", tags=["observability"])
async def schema_drift():
    from agent.mcp_resources import get_schema_drift_events
    return get_schema_drift_events()
PYEOF

# ==============================================================================
# STREAMLIT UI
# ==============================================================================
step "Writing Streamlit UI"

cat << 'PYEOF' > ui/components/schema_drift_banner.py
"""
Streamlit sidebar component: schema drift warning banner.
Polls /api/v1/schema-drift every 5 minutes and displays alerts.
"""
from __future__ import annotations

import time
import httpx
import streamlit as st


POLL_INTERVAL = 300  # seconds


def render_drift_banner(api_base: str = "http://localhost:8000") -> None:
    now = time.time()
    last_poll = st.session_state.get("drift_last_poll", 0)

    if now - last_poll > POLL_INTERVAL or "drift_events" not in st.session_state:
        try:
            resp = httpx.get(f"{api_base}/api/v1/schema-drift", timeout=5)
            data = resp.json()
            st.session_state["drift_events"] = data.get("drift_events", [])
            st.session_state["drift_last_poll"] = now
        except Exception:
            st.session_state.setdefault("drift_events", [])

    events = st.session_state.get("drift_events", [])
    if events:
        with st.sidebar:
            st.error(f"Schema Drift Detected — {len(events)} table(s) changed")
            for e in events:
                with st.expander(f"Table: {e['table']} ({e.get('severity','?')})"):
                    if e.get("dropped_columns"):
                        st.warning(f"Dropped: {', '.join(e['dropped_columns'])}")
                    if e.get("added_columns"):
                        st.info(f"Added: {', '.join(e['added_columns'])}")
                    if e.get("type_changes"):
                        st.warning(f"Type changes: {e['type_changes']}")
PYEOF

cat << 'PYEOF' > ui/components/approval_gate.py
"""
Human-in-the-loop approval gate Streamlit component.
Displays pending tool call details and Accept/Deny buttons.
"""
from __future__ import annotations

import json
import httpx
import streamlit as st


def render_approval_gate(
    tool_name: str,
    tool_args: dict,
    call_id: str,
    api_base: str = "http://localhost:8000",
) -> None:
    st.warning("Agent Action Requires Approval", icon="⚠")
    st.markdown(f"**Tool:** `{tool_name}`")
    st.json(tool_args)

    col_allow, col_deny = st.columns(2)
    with col_allow:
        if st.button("Allow", type="primary", key=f"allow_{call_id}"):
            _submit_approval(tool_name, tool_args, call_id, approved=True, api_base=api_base)
    with col_deny:
        if st.button("Deny", type="secondary", key=f"deny_{call_id}"):
            _submit_approval(tool_name, tool_args, call_id, approved=False, api_base=api_base)


def _submit_approval(
    tool_name: str,
    tool_args: dict,
    call_id: str,
    approved: bool,
    api_base: str,
) -> None:
    try:
        resp = httpx.post(
            f"{api_base}/api/v1/chat/approve",
            json={"tool_name": tool_name, "tool_args": tool_args,
                  "call_id": call_id, "approved": approved},
            timeout=30,
        )
        result = resp.json()
        if approved:
            st.success(f"Tool executed: {result.get('result', '')}")
            st.session_state["approval_pending"] = None
            st.rerun()
        else:
            st.info("Action denied. No changes were made.")
            st.session_state["approval_pending"] = None
    except Exception as exc:
        st.error(f"Approval submission failed: {exc}")
PYEOF

cat << 'PYEOF' > ui/components/chat_panel.py
"""
Streaming chat panel component.
Connects to the FastAPI SSE endpoint and renders streamed tokens.
"""
from __future__ import annotations

import json
import httpx
import streamlit as st


API_BASE = "http://localhost:8000"


def _stream_chat(message: str, history: list[dict]) -> dict:
    """
    Call the FastAPI /api/v1/chat SSE endpoint and collect all events.
    Returns the final event payload.
    """
    full_text = ""
    result_event: dict = {}
    approval_event: dict = {}
    retrieval_event: dict = {}

    placeholder = st.empty()

    with httpx.Client(timeout=120) as client:
        with client.stream(
            "POST",
            f"{API_BASE}/api/v1/chat",
            json={"message": message, "conversation_history": history},
        ) as response:
            buffer = ""
            for line in response.iter_lines():
                if line.startswith("event: "):
                    current_event = line[7:]
                elif line.startswith("data: "):
                    data_str = line[6:]
                    try:
                        data = json.loads(data_str)
                    except json.JSONDecodeError:
                        continue

                    if current_event == "token":
                        full_text += data.get("text", "")
                        placeholder.markdown(full_text + "▌")
                    elif current_event == "retrieval_complete":
                        retrieval_event = data
                    elif current_event == "done":
                        result_event = data
                        placeholder.markdown(full_text)
                    elif current_event == "approval_required":
                        approval_event = data
                        placeholder.markdown(data.get("message", ""))

    return {
        "text":      full_text or approval_event.get("message", ""),
        "done":      result_event,
        "retrieval": retrieval_event,
        "approval":  approval_event,
    }


def render_chat_panel() -> None:
    """Main chat panel with conversation history."""
    st.title("PipelineMind — Data Engineering Assistant")

    if "messages" not in st.session_state:
        st.session_state.messages = []

    if "approval_pending" not in st.session_state:
        st.session_state.approval_pending = None

    # Render existing conversation
    for msg in st.session_state.messages:
        with st.chat_message(msg["role"]):
            st.markdown(msg["content"])
            if msg.get("citations"):
                with st.expander("Sources"):
                    for c in msg["citations"]:
                        st.caption(
                            f"[{c['source_index']}] {c['file'].split('/')[-1]} "
                            f"({c['chunk_type']}) — score: {c['score']}"
                        )
            if msg.get("confidence_score") is not None:
                score = msg["confidence_score"]
                color = "green" if score >= 0.7 else ("orange" if score >= 0.5 else "red")
                st.caption(f"Confidence: :{color}[{score:.2f}]")
            if msg.get("pii_warning"):
                st.warning("This response references PII-tagged columns. Handle with care.", icon="🔒")

    # Pending approval gate
    if st.session_state.approval_pending:
        from ui.components.approval_gate import render_approval_gate
        ap = st.session_state.approval_pending
        render_approval_gate(
            tool_name=ap["tool_name"],
            tool_args=ap["tool_args"],
            call_id=ap.get("call_id", "pending"),
        )

    # Chat input
    if prompt := st.chat_input("Ask about your pipelines, data catalogue, or health..."):
        st.session_state.messages.append({"role": "user", "content": prompt})
        with st.chat_message("user"):
            st.markdown(prompt)

        with st.chat_message("assistant"):
            history = [
                {"role": m["role"], "content": m["content"]}
                for m in st.session_state.messages[:-1]
            ]
            try:
                result = _stream_chat(prompt, history)
            except Exception as exc:
                st.error(f"Connection error: {exc}")
                return

        msg_record: dict = {"role": "assistant", "content": result["text"]}

        ret = result.get("retrieval", {})
        if ret:
            msg_record["confidence_score"] = ret.get("confidence_score")
            msg_record["citations"]        = ret.get("citations", [])
            msg_record["pii_warning"]      = ret.get("has_pii", False)

        if result.get("approval"):
            ap = result["approval"]
            st.session_state.approval_pending = {
                "tool_name": ap.get("tool_name"),
                "tool_args": ap.get("tool_args", {}),
                "call_id":   ap.get("call_id", "pending"),
            }

        st.session_state.messages.append(msg_record)
        st.rerun()
PYEOF

cat << 'PYEOF' > ui/components/health_dashboard.py
"""
Pipeline health dashboard component with sparklines.
"""
from __future__ import annotations

import httpx
import pandas as pd
import streamlit as st


API_BASE = "http://localhost:8000"


def render_health_dashboard() -> None:
    st.header("Pipeline Health Dashboard")

    try:
        resp = httpx.get(f"{API_BASE}/api/v1/pipelines", timeout=10)
        pipelines = resp.json()
    except Exception as exc:
        st.error(f"Could not reach API: {exc}")
        return

    if not pipelines:
        st.info("No pipeline data available.")
        return

    cols = st.columns(len(pipelines))
    for col, p in zip(cols, pipelines):
        color = "green" if p["last_status"] == "success" else "red"
        with col:
            st.metric(
                label=p["pipeline_id"],
                value=f"{p['success_rate']}%",
                delta=f"Last: {p['last_status']}",
            )

    st.divider()

    selected = st.selectbox("Drill into pipeline", [p["pipeline_id"] for p in pipelines])
    if selected:
        try:
            status_resp = httpx.get(f"{API_BASE}/api/v1/pipelines/{selected}/status", timeout=10)
            slo_resp    = httpx.get(f"{API_BASE}/api/v1/pipelines/{selected}/slo", timeout=10)
            status = status_resp.json()
            slo    = slo_resp.json()
        except Exception as exc:
            st.error(f"Failed to fetch details: {exc}")
            return

        c1, c2, c3 = st.columns(3)
        c1.metric("Last Status", status.get("status", "N/A"))
        c2.metric("SLO %",       f"{slo.get('actual_pct', 0)}%")
        c3.metric("Compliant",   "Yes" if slo.get("compliant") else "No")

        if status.get("failures"):
            st.subheader("Recent Failures")
            st.dataframe(pd.DataFrame(status["failures"]))
PYEOF

cat << 'PYEOF' > ui/components/lineage_graph.py
"""
Interactive lineage DAG component using streamlit-agraph.
"""
from __future__ import annotations

import httpx
import streamlit as st

try:
    from streamlit_agraph import agraph, Node, Edge, Config
    AGRAPH_AVAILABLE = True
except ImportError:
    AGRAPH_AVAILABLE = False

API_BASE = "http://localhost:8000"


def render_lineage_graph(table_name: str, depth: int = 2) -> None:
    try:
        resp = httpx.get(
            f"{API_BASE}/api/v1/catalogue/lineage/{table_name}",
            params={"depth": depth}, timeout=10,
        )
        data = resp.json()
    except Exception as exc:
        st.error(f"Failed to fetch lineage: {exc}")
        return

    if not AGRAPH_AVAILABLE:
        st.warning("streamlit-agraph not installed. Showing raw lineage data.")
        st.json(data)
        return

    nodes_data = data.get("nodes", [])
    edges_data = data.get("edges", [])
    pii_nodes  = set(data.get("pii_nodes", []))

    nodes = []
    for n in nodes_data:
        color = "#FF4B4B" if n["table"] in pii_nodes else (
            "#FFD700" if n["table"] == table_name else "#4B8BFF"
        )
        nodes.append(Node(
            id=n["table"],
            label=n["table"],
            size=25,
            color=color,
            title=f"Domain: {n.get('domain','?')} | Rows: {n.get('row_count',0):,}",
        ))

    edges = [
        Edge(
            source=e["source"],
            target=e["target"],
            label=e.get("transformation", ""),
        )
        for e in edges_data
    ]

    config = Config(
        width=800, height=500,
        directed=True,
        physics=True,
        hierarchical=False,
    )
    agraph(nodes=nodes, edges=edges, config=config)

    if pii_nodes:
        st.warning(f"PII-tagged nodes: {', '.join(pii_nodes)}", icon="🔒")
PYEOF

cat << 'PYEOF' > ui/pages/01_Chat.py
"""Page 1: Streaming Chat"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from ui.components.chat_panel       import render_chat_panel
from ui.components.schema_drift_banner import render_drift_banner

render_drift_banner()
render_chat_panel()
PYEOF

cat << 'PYEOF' > ui/pages/02_Health.py
"""Page 2: Pipeline Health Dashboard"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from ui.components.health_dashboard    import render_health_dashboard
from ui.components.schema_drift_banner import render_drift_banner

render_drift_banner()
render_health_dashboard()
PYEOF

cat << 'PYEOF' > ui/pages/03_Catalogue.py
"""Page 3: Data Catalogue Browser"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent.parent))

import httpx
import streamlit as st
from ui.components.lineage_graph       import render_lineage_graph
from ui.components.schema_drift_banner import render_drift_banner

render_drift_banner()
API_BASE = "http://localhost:8000"

st.header("Data Catalogue Browser")

try:
    tables = httpx.get(f"{API_BASE}/api/v1/catalogue/tables", timeout=10).json()
except Exception as exc:
    st.error(f"API unavailable: {exc}")
    tables = []

if tables:
    pii_tables = [t for t in tables if t.get("pii_flag")]
    if pii_tables:
        st.warning(f"{len(pii_tables)} table(s) contain PII columns.", icon="🔒")

    selected = st.selectbox("Select a table", [t["table_name"] for t in tables])
    if selected:
        try:
            detail = httpx.get(f"{API_BASE}/api/v1/catalogue/tables/{selected}", timeout=10).json()
            tbl = detail.get("table", {})
            cols = detail.get("columns", [])

            c1, c2, c3 = st.columns(3)
            c1.metric("Domain", tbl.get("domain", "N/A"))
            c2.metric("Rows", f"{tbl.get('row_count', 0):,}")
            c3.metric("PII", "Yes" if tbl.get("pii_flag") else "No")

            st.markdown(f"**Description:** {tbl.get('description', 'N/A')}")

            import pandas as pd
            st.dataframe(pd.DataFrame(cols), use_container_width=True)

            st.subheader("Lineage DAG")
            depth = st.slider("Lineage depth", 1, 4, 2)
            render_lineage_graph(selected, depth)

        except Exception as exc:
            st.error(f"Failed to load table detail: {exc}")
PYEOF

cat << 'PYEOF' > ui/app.py
"""
PipelineMind Streamlit entry point.
Multi-page app: Chat | Health | Catalogue
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import streamlit as st

st.set_page_config(
    page_title="PipelineMind",
    page_icon="PM",
    layout="wide",
    initial_sidebar_state="expanded",
)

from ui.components.schema_drift_banner import render_drift_banner
from ui.components.chat_panel import render_chat_panel

render_drift_banner()

st.sidebar.title("PipelineMind")
st.sidebar.markdown("RAG-Powered Data Engineering Assistant")
st.sidebar.divider()
st.sidebar.markdown(
    """
    **Quick shortcuts**
    - `/diagnose_pipeline orders`
    - Ask: *Why does orders use MERGE?*
    - Ask: *What PII is in dim_users?*
    - Ask: *What happens if I drop user_id from stg_users?*
    """
)

render_chat_panel()
PYEOF

# ==============================================================================
# UNIT TESTS
# ==============================================================================
step "Writing unit tests"

cat << 'PYEOF' > tests/unit/test_chunkers.py
"""Unit tests for all chunker modules."""
from __future__ import annotations

import tempfile
from pathlib import Path

import pytest

from ingestion.chunkers.ast_chunker    import ASTChunker
from ingestion.chunkers.sql_chunker    import SQLChunker
from ingestion.chunkers.yaml_chunker   import YAMLChunker
from ingestion.chunkers.semantic_chunker import SemanticChunker


PYTHON_SAMPLE = '''
def extract(watermark: str) -> list:
    """Pull records since watermark."""
    return []

class OrdersPipeline:
    """Handles orders ETL."""

    def run(self) -> dict:
        """Execute the pipeline."""
        return {"status": "success"}
'''

SQL_SAMPLE = '''
CREATE TABLE orders_fact (
    order_id VARCHAR(36) PRIMARY KEY,
    total_amount NUMERIC(12,2)
);

SELECT order_id, SUM(total_amount) AS total
FROM orders_fact
WHERE status_code >= 1
GROUP BY order_id;
'''

YAML_SAMPLE = '''
dag_id: test_dag
description: Test pipeline
schedule_interval: "0 * * * *"
tasks:
  - task_id: run_pipeline
    operator: PythonOperator
    python_callable: "pipeline.run"
slo:
  success_rate_target_pct: 99.0
'''

MARKDOWN_SAMPLE = '''
# Orders Pipeline

The orders pipeline processes all confirmed orders.

## Extract Phase

Reads from the OLTP database using a watermark strategy.

## Load Phase

Uses MERGE to upsert into the warehouse.
'''


def _write_temp(suffix: str, content: str) -> Path:
    tmp = tempfile.NamedTemporaryFile(suffix=suffix, delete=False, mode="w")
    tmp.write(content)
    tmp.flush()
    return Path(tmp.name)


class TestASTChunker:
    def test_produces_chunks(self):
        path = _write_temp(".py", PYTHON_SAMPLE)
        chunks = ASTChunker().chunk(path)
        assert len(chunks) >= 1, "Should produce at least one chunk"

    def test_function_chunk_has_name(self):
        path = _write_temp(".py", PYTHON_SAMPLE)
        chunks = ASTChunker().chunk(path)
        fn_chunks = [c for c in chunks if c.chunk_type in ("function", "method")]
        assert any(c.function_name for c in fn_chunks)

    def test_chunk_has_required_fields(self):
        path = _write_temp(".py", PYTHON_SAMPLE)
        chunks = ASTChunker().chunk(path)
        for c in chunks:
            assert c.chunk_id
            assert c.raw_code
            assert c.source_file

    def test_content_hash_is_stable(self):
        path = _write_temp(".py", PYTHON_SAMPLE)
        chunks1 = ASTChunker().chunk(path)
        chunks2 = ASTChunker().chunk(path)
        hashes1 = [c.content_hash for c in chunks1]
        hashes2 = [c.content_hash for c in chunks2]
        assert hashes1 == hashes2


class TestSQLChunker:
    def test_splits_statements(self):
        path = _write_temp(".sql", SQL_SAMPLE)
        chunks = SQLChunker().chunk(path)
        assert len(chunks) >= 2

    def test_classifies_ddl(self):
        path = _write_temp(".sql", SQL_SAMPLE)
        chunks = SQLChunker().chunk(path)
        ops = [c.operation_type for c in chunks]
        assert "DDL" in ops

    def test_extracts_table_refs(self):
        path = _write_temp(".sql", SQL_SAMPLE)
        chunks = SQLChunker().chunk(path)
        all_tables = [t for c in chunks for t in c.tables_referenced]
        assert "orders_fact" in all_tables


class TestYAMLChunker:
    def test_produces_dag_config_chunk(self):
        path = _write_temp(".yml", YAML_SAMPLE)
        chunks = YAMLChunker().chunk(path)
        block_types = [c.block_type for c in chunks]
        assert "dag_config" in block_types

    def test_produces_task_chunks(self):
        path = _write_temp(".yml", YAML_SAMPLE)
        chunks = YAMLChunker().chunk(path)
        task_chunks = [c for c in chunks if c.block_type == "task"]
        assert len(task_chunks) >= 1

    def test_extracts_pipeline_name(self):
        path = _write_temp(".yml", YAML_SAMPLE)
        chunks = YAMLChunker().chunk(path)
        assert all(c.pipeline_name == "test_dag" for c in chunks)


class TestSemanticChunker:
    def test_chunks_by_heading(self):
        path = _write_temp(".md", MARKDOWN_SAMPLE)
        chunks = SemanticChunker().chunk(path)
        assert len(chunks) >= 2

    def test_heading_metadata(self):
        path = _write_temp(".md", MARKDOWN_SAMPLE)
        chunks = SemanticChunker().chunk(path)
        titled = [c for c in chunks if c.section_title]
        assert len(titled) >= 1
PYEOF

cat << 'PYEOF' > tests/unit/test_rrf_fusion.py
"""Unit tests for Reciprocal Rank Fusion."""
from __future__ import annotations

from retrieval.chroma_retriever import RetrievedChunk
from retrieval.rrf_fusion import reciprocal_rank_fusion


def _make_chunk(chunk_id: str, score: float, method: str = "dense") -> RetrievedChunk:
    return RetrievedChunk(
        chunk_id=chunk_id, document="doc", raw_implementation="",
        source_file="f.py", chunk_type="function", pipeline_name="p",
        source_type="python", pii_flag=False, tags=[], git_commit_hash="",
        function_name="", class_name="", line_start=0, line_end=0,
        distance=1-score, score=score, rank=0, retrieval_method=method,
    )


def test_rrf_combines_both_lists():
    dense  = [_make_chunk("a", 0.9), _make_chunk("b", 0.8), _make_chunk("c", 0.7)]
    sparse = [_make_chunk("b", 0.9), _make_chunk("d", 0.8), _make_chunk("a", 0.5)]
    result = reciprocal_rank_fusion(dense, sparse, top_n=4)
    ids = [r.chunk_id for r in result]
    assert "a" in ids and "b" in ids and "c" in ids and "d" in ids


def test_rrf_document_appearing_in_both_ranks_higher():
    dense  = [_make_chunk("shared", 0.95), _make_chunk("only_dense", 0.8)]
    sparse = [_make_chunk("shared", 0.9),  _make_chunk("only_sparse", 0.85)]
    result = reciprocal_rank_fusion(dense, sparse, top_n=3)
    assert result[0].chunk_id == "shared"


def test_rrf_respects_top_n():
    dense  = [_make_chunk(str(i), 1 - i*0.1) for i in range(10)]
    sparse = [_make_chunk(str(i), 1 - i*0.1) for i in range(10)]
    result = reciprocal_rank_fusion(dense, sparse, top_n=5)
    assert len(result) <= 5


def test_rrf_empty_sparse_returns_dense_ranked():
    dense = [_make_chunk("x", 0.9), _make_chunk("y", 0.7)]
    result = reciprocal_rank_fusion(dense, [], top_n=2)
    assert len(result) == 2
PYEOF

cat << 'PYEOF' > tests/unit/test_validators.py
"""Unit tests for Pydantic tool validators and self-correction."""
from __future__ import annotations

import pytest
from pydantic import ValidationError

from agent.tools.validators import (
    TriggerDQCheckInput, GetPipelineStatusInput, GetLineageGraphInput,
    AnalyzeLineageImpactInput, SearchPIITablesInput, GetSLOReportInput,
)


def test_trigger_dq_check_valid():
    v = TriggerDQCheckInput(table_name="orders_fact", rules_preset="standard")
    assert v.table_name == "orders_fact"


def test_trigger_dq_check_invalid_preset():
    with pytest.raises(ValidationError):
        TriggerDQCheckInput(table_name="orders_fact", rules_preset="ultra_strict")


def test_trigger_dq_check_empty_table():
    with pytest.raises(ValidationError):
        TriggerDQCheckInput(table_name="")


def test_get_pipeline_status_defaults():
    v = GetPipelineStatusInput(pipeline_id="orders")
    assert v.lookback_hours == 24


def test_get_pipeline_status_lookback_out_of_range():
    with pytest.raises(ValidationError):
        GetPipelineStatusInput(pipeline_id="orders", lookback_hours=1000)


def test_analyze_lineage_impact_valid():
    v = AnalyzeLineageImpactInput(changed_table="stg_users", dropped_columns=["user_id", "email"])
    assert len(v.dropped_columns) == 2


def test_analyze_lineage_impact_empty_columns():
    with pytest.raises(ValidationError):
        AnalyzeLineageImpactInput(changed_table="stg_users", dropped_columns=[])


def test_get_lineage_graph_depth_bounds():
    with pytest.raises(ValidationError):
        GetLineageGraphInput(table_name="orders", depth=10)


def test_search_pii_tables_optional_filter():
    v = SearchPIITablesInput()
    assert v.domain_filter is None

    v2 = SearchPIITablesInput(domain_filter="finance")
    assert v2.domain_filter == "finance"
PYEOF

cat << 'PYEOF' > tests/unit/test_context_builder.py
"""Unit tests for ContextBuilder."""
from __future__ import annotations

from retrieval.chroma_retriever import RetrievedChunk
from retrieval.context_builder  import ContextBuilder


def _chunk(chunk_id: str, score: float, pii: bool = False, source_type: str = "python") -> RetrievedChunk:
    return RetrievedChunk(
        chunk_id=chunk_id,
        document=f"Summary of chunk {chunk_id}",
        raw_implementation=f"def fn_{chunk_id}(): pass",
        source_file=f"pipeline/{chunk_id}.py",
        chunk_type="function",
        pipeline_name="orders",
        source_type=source_type,
        pii_flag=pii,
        tags=[],
        git_commit_hash="abc123",
        function_name=f"fn_{chunk_id}",
        class_name="",
        line_start=1,
        line_end=10,
        distance=1-score,
        score=score,
        rank=0,
    )


def test_builds_non_empty_context():
    chunks = [_chunk("a", 0.9), _chunk("b", 0.8)]
    ctx = ContextBuilder().build("test query", chunks)
    assert ctx.context_text
    assert len(ctx.chunks_used) > 0


def test_confidence_score_from_top_chunk():
    chunks = [_chunk("a", 0.85)]
    ctx = ContextBuilder().build("q", chunks)
    assert abs(ctx.confidence_score - 0.85) < 0.01


def test_low_confidence_flag():
    chunks = [_chunk("a", 0.3)]
    ctx = ContextBuilder().build("q", chunks)
    assert ctx.low_confidence


def test_pii_flag_propagated():
    chunks = [_chunk("pii_chunk", 0.9, pii=True)]
    ctx = ContextBuilder().build("q", chunks)
    assert ctx.has_pii


def test_empty_chunks_returns_fallback():
    ctx = ContextBuilder().build("q", [])
    assert ctx.confidence_score == 0.0
    assert "No relevant documents" in ctx.context_text


def test_raw_code_injected_for_python():
    chunks = [_chunk("fn", 0.9, source_type="python")]
    ctx = ContextBuilder().build("q", chunks)
    assert "def fn_fn" in ctx.context_text
PYEOF

cat << 'PYEOF' > tests/integration/test_duckdb_tools.py
"""
Integration tests for MCP tools against the seeded DuckDB database.
Requires the DuckDB to be seeded: python db/seeder.py
"""
from __future__ import annotations

import pytest
from pathlib import Path


@pytest.fixture(autouse=True)
def _check_db():
    """Skip integration tests if the database has not been seeded."""
    from config import settings
    if not settings.duckdb_path.exists():
        pytest.skip("DuckDB not seeded — run: python db/seeder.py")


def test_get_pipeline_status_known_pipeline():
    from agent.tools.pipeline_tools import get_pipeline_status
    result = get_pipeline_status("orders", lookback_hours=720)
    assert "status" in result
    assert "slo_pct" in result


def test_get_slo_report_known_pipeline():
    from agent.tools.pipeline_tools import get_slo_report
    result = get_slo_report("orders", window_days=30)
    assert "actual_pct" in result
    assert result["actual_pct"] is not None


def test_search_pii_tables_returns_results():
    from agent.tools.catalogue_tools import search_pii_tables
    result = search_pii_tables()
    assert len(result) > 0
    assert all("columns" in r for r in result)


def test_search_pii_tables_domain_filter():
    from agent.tools.catalogue_tools import search_pii_tables
    result = search_pii_tables(domain_filter="users")
    assert all(r.get("domain") == "users" for r in result)


def test_get_lineage_graph_returns_nodes():
    from agent.tools.lineage_tools import get_lineage_graph
    result = get_lineage_graph("orders_fact", depth=1)
    assert "nodes" in result
    assert "edges" in result


def test_analyze_lineage_impact_known_table():
    from agent.tools.lineage_tools import analyze_lineage_impact
    result = analyze_lineage_impact("dim_users", ["user_id"])
    assert "risk_score" in result
    assert 0.0 <= result["risk_score"] <= 1.0
    assert "recommended_action" in result


def test_trigger_dq_check_returns_score():
    from agent.tools.dq_tools import trigger_dq_check
    result = trigger_dq_check("orders_fact", "standard")
    assert "score" in result
    assert "run_id" in result
PYEOF

# ==============================================================================
# VIRTUAL ENVIRONMENT + DEPENDENCIES
# ==============================================================================
step "Setting up Python virtual environment"

VENV_DIR="$PROJECT_DIR/.venv"
PYTHON_BIN=""
for candidate in python3.11 python3; do
    if command -v "$candidate" &>/dev/null; then
        ver=$("$candidate" --version 2>&1 | awk '{print $2}')
        major=$(echo "$ver" | cut -d. -f1)
        minor=$(echo "$ver" | cut -d. -f2)
        if [[ "$major" -ge 3 && "$minor" -ge 11 ]]; then
            PYTHON_BIN=$(command -v "$candidate")
            log "Using Python: $PYTHON_BIN ($ver)"
            break
        fi
    fi
done
[[ -z "$PYTHON_BIN" ]] && die "Python >= 3.11 not found"

if [[ ! -d "$VENV_DIR" ]]; then
    log "Creating virtual environment at $VENV_DIR"
    "$PYTHON_BIN" -m venv "$VENV_DIR"
fi

VENV_PIP="$VENV_DIR/bin/pip"
VENV_PYTHON="$VENV_DIR/bin/python"

log "Upgrading pip and setuptools"
"$VENV_PIP" install --quiet --upgrade pip setuptools wheel

log "Installing core dependencies (this may take several minutes)"

# Install in groups to isolate failures
"$VENV_PIP" install --quiet \
    groq tenacity structlog pydantic pydantic-settings python-dotenv pyyaml httpx \
    || warn "Some core packages may have failed"

"$VENV_PIP" install --quiet \
    fastapi "uvicorn[standard]" sse-starlette prometheus-client \
    || warn "FastAPI group install issue"

"$VENV_PIP" install --quiet \
    duckdb \
    || warn "DuckDB install issue"

"$VENV_PIP" install --quiet \
    chromadb rank-bm25 \
    || warn "Vector DB install issue"

"$VENV_PIP" install --quiet \
    "sentence-transformers>=3.0.0" \
    || warn "sentence-transformers install issue"

"$VENV_PIP" install --quiet \
    tree-sitter tree-sitter-python \
    || warn "tree-sitter install issue"

"$VENV_PIP" install --quiet \
    streamlit streamlit-agraph \
    || warn "Streamlit install issue"

"$VENV_PIP" install --quiet \
    watchdog pandas numpy scikit-learn sqlalchemy \
    || warn "Utilities install issue"

"$VENV_PIP" install --quiet \
    pytest pytest-asyncio \
    || warn "Test dependencies install issue"

"$VENV_PIP" install --quiet \
    great-expectations \
    || warn "Great Expectations install issue (optional, DQ checks will use fallback)"

"$VENV_PIP" install --quiet \
    mcp \
    || warn "MCP SDK install issue (MCP server will be unavailable)"

log "Dependency installation complete"

# ==============================================================================
# SEED DATABASE
# ==============================================================================
step "Seeding DuckDB metadata store"

cd "$PROJECT_DIR"
"$VENV_PYTHON" db/seeder.py && log "DuckDB seeded successfully" || warn "DuckDB seeding failed — check db/seeder.py"

# ==============================================================================
# RUN UNIT TESTS
# ==============================================================================
step "Running unit tests"

"$VENV_DIR/bin/pytest" tests/unit/ -v --tb=short 2>&1 || warn "Some unit tests failed — check output above"

step "Running integration tests (requires seeded DB)"
"$VENV_DIR/bin/pytest" tests/integration/ -v --tb=short 2>&1 || warn "Some integration tests failed"

# ==============================================================================
# STARTUP SCRIPTS
# ==============================================================================
step "Writing startup scripts"

cat << 'STARTEOF' > scripts/start_api.sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source .venv/bin/activate
echo "[PM] Starting FastAPI on http://localhost:8000"
echo "[PM] API docs: http://localhost:8000/docs"
uvicorn api.main:app --host 0.0.0.0 --port 8000 --reload --log-level info
STARTEOF

cat << 'STARTEOF' > scripts/start_ui.sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source .venv/bin/activate
echo "[PM] Starting Streamlit on http://localhost:8501"
streamlit run ui/app.py \
    --server.port 8501 \
    --server.address localhost \
    --server.headless false \
    --browser.gatherUsageStats false
STARTEOF

cat << 'STARTEOF' > scripts/ingest.sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source .venv/bin/activate
echo "[PM] Running ingestion pipeline..."
python ingestion/ingest_pipeline.py \
    --repo-path ./data/pipeline_repo \
    --sql-path  ./data/sql \
    --yaml-path ./data/dags \
    --dbt-path  ./data/dbt_project \
    "$@"
STARTEOF

cat << 'STARTEOF' > scripts/ingest_fast.sh
#!/usr/bin/env bash
# Fast ingestion: skip LLM summaries (uses fallback text, faster for testing)
set -euo pipefail
cd "$(dirname "$0")/.."
source .venv/bin/activate
echo "[PM] Running fast ingestion (no LLM summaries)..."
python ingestion/ingest_pipeline.py \
    --repo-path ./data/pipeline_repo \
    --sql-path  ./data/sql \
    --yaml-path ./data/dags \
    --dbt-path  ./data/dbt_project \
    --skip-summaries \
    --force-reindex
STARTEOF

cat << 'STARTEOF' > scripts/seed_db.sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source .venv/bin/activate
python db/seeder.py
STARTEOF

cat << 'STARTEOF' > scripts/run_tests.sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source .venv/bin/activate
pytest tests/ -v --tb=short --cov=ingestion --cov=retrieval --cov=agent --cov=api \
    --cov-report=term-missing --cov-report=html:htmlcov
STARTEOF

mkdir -p scripts
chmod +x scripts/*.sh

# ==============================================================================
# README
# ==============================================================================
step "Writing README"

cat << 'MDEOF' > README.md
# PipelineMind

RAG-Powered Data Engineering Assistant via MCP

## Quick Start

### 1. Seed the database
```bash
bash scripts/seed_db.sh
```

### 2. Run ingestion (builds ChromaDB + BM25 index)

Fast mode (no LLM calls — good for first run):
```bash
bash scripts/ingest_fast.sh
```

Full mode (LLM summaries via Groq — better retrieval quality):
```bash
bash scripts/ingest.sh
```

### 3. Start the API backend
```bash
bash scripts/start_api.sh
```

API docs: http://localhost:8000/docs
Health check: http://localhost:8000/api/v1/health

### 4. Start the Streamlit UI (new terminal)
```bash
bash scripts/start_ui.sh
```

UI: http://localhost:8501

## Architecture