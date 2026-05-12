"""
get_lineage_graph and analyze_lineage_impact MCP tools.
Both query the DuckDB lineage_edges and catalogue_tables tables.
analyze_lineage_impact is the What-If Impact Engine (core innovation).
"""
from __future__ import annotations

import logging
from typing import Any

import duckdb

from pm_config import settings

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
