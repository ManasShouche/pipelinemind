"""
Pipeline status and SLO REST endpoints.
"""
from __future__ import annotations

import logging

import duckdb
from fastapi import APIRouter

from agent.tools.pipeline_tools import get_pipeline_status, get_slo_report
from pm_config import settings

logger = logging.getLogger(__name__)
router = APIRouter()


@router.get("/pipelines")
async def list_pipelines():
    """List all pipelines with their latest run status."""
    con = duckdb.connect(str(settings.duckdb_path), read_only=True)
    # DuckDB 1.x: use a subquery for last_status instead of LAST()
    rows = con.execute(
        """
        WITH ranked AS (
            SELECT
                pipeline_id,
                status,
                start_time,
                ROW_NUMBER() OVER (PARTITION BY pipeline_id ORDER BY start_time DESC) AS rn
            FROM pipeline_runs
        ),
        latest AS (
            SELECT pipeline_id, status AS last_status, start_time AS last_run
            FROM ranked WHERE rn = 1
        ),
        summary AS (
            SELECT
                pipeline_id,
                COUNT(*)                                           AS total_runs,
                SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END) AS success_count
            FROM pipeline_runs
            GROUP BY pipeline_id
        )
        SELECT s.pipeline_id, s.total_runs, s.success_count,
               l.last_run, l.last_status
        FROM summary s
        JOIN latest l USING (pipeline_id)
        ORDER BY s.pipeline_id
        """
    ).fetchall()
    con.close()
    return [
        {
            "pipeline_id":  r[0],
            "total_runs":   r[1],
            "success_rate": round(r[2] / r[1] * 100, 2) if r[1] else 0,
            "last_run":     r[3],
            "last_status":  r[4],
        }
        for r in rows
    ]


@router.get("/pipelines/{pipeline_id}/status")
async def pipeline_status(pipeline_id: str, lookback_hours: int = 24):
    return get_pipeline_status(pipeline_id, lookback_hours)


@router.get("/pipelines/{pipeline_id}/slo")
async def pipeline_slo(pipeline_id: str, window_days: int = 7):
    return get_slo_report(pipeline_id, window_days)
