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
    from pm_config import settings
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
