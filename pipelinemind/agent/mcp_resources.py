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

from pm_config import settings

logger = logging.getLogger(__name__)


def get_schema_drift_events() -> dict:
    """
    Compare current catalogue_columns against the latest schema_snapshot baseline.
    Returns drift events suitable for display in the Streamlit sidebar.
    Returns a safe "not_ready" payload if the DB doesn't exist or isn't seeded yet.
    """
    if not settings.duckdb_path.exists():
        return {
            "drift_events": [],
            "polled_at": datetime.utcnow().isoformat(),
            "status": "db_not_seeded",
            "message": "Run: python db/seeder.py to initialise the database.",
        }

    try:
        con = duckdb.connect(str(settings.duckdb_path), read_only=True)
    except Exception as exc:
        logger.warning("Could not connect to DuckDB: %s", exc)
        return {"drift_events": [], "polled_at": datetime.utcnow().isoformat(), "status": "db_error"}

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
    except Exception as exc:
        logger.warning("Schema drift check failed: %s", exc)
        return {
            "drift_events": [],
            "polled_at": datetime.utcnow().isoformat(),
            "status": "not_ready",
            "message": str(exc),
        }
    finally:
        con.close()

