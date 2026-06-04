"""
Tests for intent-aware tool filtering and iteration budget in AgentLoop.
These are the core behavioral tests for the over-agentic fix.
"""
from __future__ import annotations

import pytest
from agent.agent_loop import (
    _get_tools_for_intent,
    _get_max_iterations,
    INTENT_TOOL_ALLOWLIST,
    INTENT_MAX_ITERATIONS,
)


class TestIntentToolFiltering:
    def test_catalogue_only_gets_lineage_and_pii_tools(self):
        tools = _get_tools_for_intent("CATALOGUE")
        names = [t["function"]["name"] for t in tools]
        assert "get_lineage_graph" in names
        assert "search_pii_tables" in names
        # These must NOT be present for CATALOGUE intent
        assert "get_pipeline_status" not in names
        assert "get_slo_report" not in names
        assert "analyze_lineage_impact" not in names
        assert "trigger_dq_check" not in names

    def test_health_only_gets_status_and_slo_tools(self):
        tools = _get_tools_for_intent("HEALTH")
        names = [t["function"]["name"] for t in tools]
        assert "get_pipeline_status" in names
        assert "get_slo_report" in names
        assert "get_lineage_graph" not in names
        assert "trigger_dq_check" not in names

    def test_code_qa_gets_no_tools(self):
        tools = _get_tools_for_intent("CODE_QA")
        assert tools == []

    def test_general_gets_no_tools(self):
        tools = _get_tools_for_intent("GENERAL")
        assert tools == []

    def test_action_gets_all_tools(self):
        tools = _get_tools_for_intent("ACTION")
        names = [t["function"]["name"] for t in tools]
        assert len(names) == 6
        assert "trigger_dq_check" in names
        assert "analyze_lineage_impact" in names

    def test_unknown_intent_gets_full_capability(self):
        tools = _get_tools_for_intent(None)
        assert len(tools) == 6


class TestIntentIterationBudget:
    def test_catalogue_max_one_iteration(self):
        assert _get_max_iterations("CATALOGUE") == 1

    def test_health_max_two_iterations(self):
        assert _get_max_iterations("HEALTH") == 2

    def test_action_max_five_iterations(self):
        assert _get_max_iterations("ACTION") == 5

    def test_code_qa_zero_iterations(self):
        assert _get_max_iterations("CODE_QA") == 0

    def test_general_zero_iterations(self):
        assert _get_max_iterations("GENERAL") == 0

    def test_unknown_intent_conservative_budget(self):
        assert _get_max_iterations(None) == 3


class TestAllowlistCompleteness:
    def test_all_intents_are_covered(self):
        expected_intents = {"CODE_QA", "CATALOGUE", "HEALTH", "ACTION", "GENERAL", None}
        assert set(INTENT_TOOL_ALLOWLIST.keys()) == expected_intents

    def test_all_intents_have_budget(self):
        expected_intents = {"CODE_QA", "CATALOGUE", "HEALTH", "ACTION", "GENERAL", None}
        assert set(INTENT_MAX_ITERATIONS.keys()) == expected_intents

    def test_no_tools_exceed_registry(self):
        from agent.agent_loop import TOOL_REGISTRY
        all_allowed = {t for tools in INTENT_TOOL_ALLOWLIST.values() for t in tools}
        assert all_allowed.issubset(set(TOOL_REGISTRY.keys()))
