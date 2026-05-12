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
