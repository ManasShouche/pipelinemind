"""
Unit tests for the keyword fast-path intent classifier.
Every query that was previously misclassified must now route correctly
without making a single LLM call.
"""
from __future__ import annotations

from retrieval.intent_classifier import IntentClassifier, Intent, _keyword_classify


class TestKeywordFastPath:
    """Ensure keyword rules route correctly without LLM calls."""

    def test_lineage_dag_query_is_catalogue(self):
        result = _keyword_classify("can you let me know about vw_revenue_by_tier table lineage dag")
        assert result is not None
        intent, conf = result
        assert intent == Intent.CATALOGUE
        assert conf >= 0.90

    def test_lineage_graph_query_is_catalogue(self):
        result = _keyword_classify("show me the lineage graph for orders_fact")
        assert result is not None
        assert result[0] == Intent.CATALOGUE

    def test_upstream_query_is_catalogue(self):
        result = _keyword_classify("what tables are upstream of dim_users")
        assert result is not None
        assert result[0] == Intent.CATALOGUE

    def test_pii_query_is_catalogue(self):
        result = _keyword_classify("what PII columns exist in the users table")
        assert result is not None
        assert result[0] == Intent.CATALOGUE

    def test_what_columns_is_catalogue(self):
        result = _keyword_classify("what columns are in the orders_fact table?")
        assert result is not None
        assert result[0] == Intent.CATALOGUE

    def test_downstream_is_catalogue(self):
        result = _keyword_classify("which tables depend on sessions_agg downstream?")
        assert result is not None
        assert result[0] == Intent.CATALOGUE

    def test_pipeline_failed_is_health(self):
        result = _keyword_classify("did the orders pipeline fail today?")
        assert result is not None
        assert result[0] == Intent.HEALTH

    def test_slo_breach_is_health(self):
        result = _keyword_classify("show me SLO breach events for the last 7 days")
        assert result is not None
        assert result[0] == Intent.HEALTH

    def test_what_if_drop_is_action(self):
        result = _keyword_classify("what if I drop user_id from stg_users?")
        assert result is not None
        assert result[0] == Intent.ACTION

    def test_what_happens_if_is_action(self):
        result = _keyword_classify("what happens if I rename the customer_id column?")
        assert result is not None
        assert result[0] == Intent.ACTION

    def test_run_dq_check_is_action(self):
        result = _keyword_classify("run a DQ check on the orders table")
        assert result is not None
        assert result[0] == Intent.ACTION

    def test_code_explanation_is_code_qa(self):
        result = _keyword_classify("why does the orders pipeline use MERGE strategy?")
        assert result is not None
        assert result[0] == Intent.CODE_QA

    def test_how_does_function_work_is_code_qa(self):
        result = _keyword_classify("how does the extract function in orders_pipeline.py work?")
        assert result is not None
        assert result[0] == Intent.CODE_QA

    def test_general_concept_is_general(self):
        result = _keyword_classify("what is incremental loading in data engineering?")
        assert result is not None
        assert result[0] == Intent.GENERAL

    def test_ambiguous_query_returns_none_for_llm(self):
        # Generic question with no strong keyword signal → LLM should handle
        result = _keyword_classify("tell me about the data")
        # May or may not match — test that if it returns something it's valid
        if result is not None:
            assert result[0] in Intent.__members__.values()


class TestKeywordConfidenceThreshold:
    def test_catalogue_confidence_is_high(self):
        _, conf = _keyword_classify("show lineage dag for vw_revenue_by_tier")
        assert conf >= 0.90

    def test_health_confidence_is_high(self):
        _, conf = _keyword_classify("pipeline failed last night")
        assert conf >= 0.90


class TestHallucinationDetection:
    def test_detects_calling_prefix(self):
        from agent.agent_loop import _has_hallucinated_tool_call
        assert _has_hallucinated_tool_call("[Calling get_lineage_graph for vw_revenue_by_tier]")

    def test_detects_i_will_call(self):
        from agent.agent_loop import _has_hallucinated_tool_call
        assert _has_hallucinated_tool_call("I will call the get_lineage_graph tool.")

    def test_clean_text_not_flagged(self):
        from agent.agent_loop import _has_hallucinated_tool_call
        assert not _has_hallucinated_tool_call(
            "The vw_revenue_by_tier table depends on orders_fact and dim_users."
        )

    def test_strip_removes_fabricated_text(self):
        from agent.agent_loop import _strip_hallucination
        raw = (
            "I will call the get_lineage_graph tool. Please wait. "
            "[Calling get_lineage_graph for vw_revenue_by_tier] "
            "The table depends on orders_fact and dim_users."
        )
        cleaned = _strip_hallucination(raw)
        assert "[Calling" not in cleaned
        assert "I will call" not in cleaned
        assert "orders_fact" in cleaned


class TestSigmoidScoreNormalisation:
    def test_positive_logit_above_half(self):
        from retrieval.reranker import _sigmoid
        assert _sigmoid(2.0) > 0.5

    def test_negative_logit_below_half(self):
        from retrieval.reranker import _sigmoid
        assert _sigmoid(-3.0) < 0.5

    def test_zero_logit_is_half(self):
        from retrieval.reranker import _sigmoid
        assert abs(_sigmoid(0.0) - 0.5) < 0.001

    def test_large_negative_near_zero(self):
        from retrieval.reranker import _sigmoid
        assert _sigmoid(-10.0) < 0.01
