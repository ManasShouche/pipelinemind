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
from pm_config import settings

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
