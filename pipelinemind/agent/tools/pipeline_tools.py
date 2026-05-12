"""
get_pipeline_status and get_slo_report MCP tools.
Both query the DuckDB pipeline_runs and slo_definitions tables.
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta
from typing import Any

import duckdb

from pm_config import settings

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
