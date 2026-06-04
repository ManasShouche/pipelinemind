"""
Intent classifier with two-stage routing:

Stage 1 — Keyword fast-path (zero latency, zero quota):
  Matches deterministic signal words before the LLM is ever called.
  DE-domain queries almost always contain one of these signals.
  Examples:
    "lineage dag for vw_revenue_by_tier"  → CATALOGUE  (keyword: "lineage", "dag")
    "what pii columns are in dim_users"   → CATALOGUE  (keyword: "pii", "column")
    "did orders fail today"               → HEALTH     (keyword: "fail", "status")
    "what if I drop user_id"              → ACTION     (keyword: "drop", "what if")
    "how does the merge function work"    → CODE_QA    (keyword: "how does", "function")
    "explain incremental loading"         → GENERAL    (keyword: "explain", "what is")

Stage 2 — LLM classifier (llama3-8b, temperature=0.0):
  Fires only when keyword stage returns no match.
  Now includes 10 few-shot examples so 8b reliably handles ambiguous phrasing.
"""
from __future__ import annotations

import json
import logging
import re
from enum import Enum

from tenacity import retry, stop_after_attempt, wait_exponential

from agent.llm_router import CallType, router

logger = logging.getLogger(__name__)


class Intent(str, Enum):
    CODE_QA   = "CODE_QA"
    CATALOGUE = "CATALOGUE"
    HEALTH    = "HEALTH"
    ACTION    = "ACTION"
    GENERAL   = "GENERAL"


# ── Stage 1: Keyword fast-path rules ─────────────────────────────────────────
# Order matters — more specific patterns first.
# Each tuple: (compiled_regex, Intent, confidence)

_KEYWORD_RULES: list[tuple[re.Pattern, Intent, float]] = [
    # ACTION — explicit destructive/change-intent signals
    (re.compile(
        r"\b(what\s+if|what\s+happens\s+if|what\s+would\s+happen|impact\s+of\s+drop"
        r"|if\s+i\s+drop|if\s+i\s+rename|before\s+i\s+drop|blast\s+radius"
        r"|downstream\s+impact|run\s+(a\s+)?dq|trigger\s+(a\s+)?dq"
        r"|data\s+quality\s+check|run\s+great\s+expectations)\b",
        re.I,
    ), Intent.ACTION, 0.95),

    # CATALOGUE — lineage / schema / PII discovery signals
    (re.compile(
        r"\b(lineage|lineage\s+dag|lineage\s+graph|data\s+lineage"
        r"|upstream|downstream|depends\s+on|which\s+tables"
        r"|pii\s+columns?|pii\s+table|sensitive\s+columns?|sensitive\s+data"
        r"|what\s+columns?|columns?\s+in|schema\s+of|schema\s+for"
        r"|data\s+catalogue|catalogue|catalog\s+table|dag\s+(for|of)"
        r"|table\s+lineage|table\s+schema|describe\s+table)\b",
        re.I,
    ), Intent.CATALOGUE, 0.95),

    # HEALTH — pipeline operational signals
    (re.compile(
        r"\b(pipeline\s+(fail|failed|failing|status|ran|ran\s+today|breach)"
        r"|slo\s+breach|slo\s+adherence|slo\s+report|success\s+rate"
        r"|last\s+run|recent\s+(fail|error|run)|did\s+\w+\s+(fail|run|succeed)"
        r"|why\s+did\s+\w+\s+fail|pipeline\s+health|run\s+history"
        r"|monitor|monitoring|alert|on-call|pagerduty)\b",
        re.I,
    ), Intent.HEALTH, 0.93),

    # CODE_QA — implementation/code understanding signals
    (re.compile(
        r"\b(how\s+does\s+the|why\s+does\s+the|why\s+is\s+the|explain\s+the\s+code"
        r"|what\s+does\s+the\s+function|what\s+does\s+this\s+(function|class|method)"
        r"|merge\s+strategy|insert\s+overwrite|scd2|scd\s+type|incremental\s+(logic|strategy)"
        r"|watermark|look\s+at\s+the\s+code|read\s+the\s+code|show\s+me\s+the\s+code"
        r"|python\s+(function|class|method)|sql\s+(query|statement|logic))\b",
        re.I,
    ), Intent.CODE_QA, 0.92),

    # GENERAL — education / concept signals (no pipeline-specific context)
    (re.compile(
        r"\b(what\s+is\s+a?\s*\w+|explain\s+what|how\s+does\s+\w+\s+work\s+in\s+general"
        r"|best\s+practice|definition\s+of|difference\s+between|compare\s+\w+\s+and"
        r"|teach\s+me|help\s+me\s+understand|what\s+are\s+(etl|elt|dbt|airflow))\b",
        re.I,
    ), Intent.GENERAL, 0.88),
]


def _keyword_classify(query: str) -> tuple[Intent, float] | None:
    """
    Fast-path keyword classification. Returns (Intent, confidence) if a
    keyword pattern matches, or None if the LLM stage should be used.
    """
    for pattern, intent, confidence in _KEYWORD_RULES:
        if pattern.search(query):
            logger.info(
                "Intent (keyword): %s (conf=%.2f) pattern='%s' query='%s...'",
                intent.value, confidence,
                pattern.pattern[:40], query[:60],
            )
            return intent, confidence
    return None


# ── Stage 2: LLM classifier with few-shot examples ───────────────────────────

_SYSTEM_PROMPT = """You are an intent classifier for a Data Engineering AI assistant.
Classify the user query into EXACTLY ONE intent.

INTENT DEFINITIONS:
CODE_QA   — questions about pipeline code logic, SQL/Python implementation, debugging.
CATALOGUE — questions about table schemas, column metadata, data lineage, lineage DAG,
             upstream/downstream dependencies, PII columns, data discovery.
HEALTH    — questions about pipeline run status, failures, SLO adherence, monitoring.
ACTION    — explicit requests to trigger DQ checks, run impact analysis before schema changes.
GENERAL   — generic data engineering education with no specific pipeline context.

DECISION RULE:
- Any question containing "lineage", "DAG", "upstream", "downstream", "PII column",
  "what columns", "schema of", or "catalogue" → CATALOGUE (never CODE_QA)
- Questions asking WHAT something IS vs HOW code works → GENERAL vs CODE_QA

FEW-SHOT EXAMPLES (use these as anchors):
Query: "What is the lineage DAG for vw_revenue_by_tier?"
{"intent": "CATALOGUE", "confidence": 0.97}

Query: "Can you let me know about vw_revenue_by_tier table lineage dag"
{"intent": "CATALOGUE", "confidence": 0.97}

Query: "What PII columns exist in the users table?"
{"intent": "CATALOGUE", "confidence": 0.96}

Query: "Which tables depend on orders_fact?"
{"intent": "CATALOGUE", "confidence": 0.95}

Query: "Did the orders pipeline fail today?"
{"intent": "HEALTH", "confidence": 0.95}

Query: "What is our SLO breach rate for the last 7 days?"
{"intent": "HEALTH", "confidence": 0.94}

Query: "What happens if I drop user_id from stg_users?"
{"intent": "ACTION", "confidence": 0.96}

Query: "Why does the orders pipeline use MERGE instead of INSERT OVERWRITE?"
{"intent": "CODE_QA", "confidence": 0.94}

Query: "How does the extract function in orders_pipeline.py work?"
{"intent": "CODE_QA", "confidence": 0.93}

Query: "What is incremental loading in data engineering?"
{"intent": "GENERAL", "confidence": 0.91}

Respond with ONLY this JSON object (no markdown, no explanation, no preamble):
{"intent": "<INTENT>", "confidence": <0.0-1.0>}"""


class IntentClassifier:
    """
    Two-stage intent classifier:
      Stage 1: keyword fast-path (no API calls, no latency)
      Stage 2: llama3-8b with few-shot examples (only when stage 1 fails)
    """

    @retry(
        stop=stop_after_attempt(3),
        wait=wait_exponential(min=1, max=8),
        reraise=False,
    )
    def classify(self, query: str) -> tuple[Intent, float]:
        """
        Returns (Intent, confidence_score).
        Falls back to CODE_QA with confidence=0.5 on any failure.
        """
        # Stage 1: keyword fast-path
        keyword_result = _keyword_classify(query)
        if keyword_result is not None:
            return keyword_result

        # Stage 2: LLM classifier
        try:
            response = router.complete(
                call_type=CallType.INTENT,
                messages=[
                    {"role": "system", "content": _SYSTEM_PROMPT},
                    {"role": "user",   "content": query},
                ],
            )
            raw = response.choices[0].message.content.strip()
            raw = raw.strip("`").strip()
            if raw.startswith("json"):
                raw = raw[4:].strip()
            parsed     = json.loads(raw)
            intent_str = parsed.get("intent", "CODE_QA")
            confidence = float(parsed.get("confidence", 0.8))
            intent     = Intent(intent_str)
            logger.info(
                "Intent (llm): %s (conf=%.2f) model=llama3-8b query='%s...'",
                intent.value, confidence, query[:60],
            )
            return intent, confidence
        except Exception as exc:
            logger.warning("Intent classification failed (%s) — defaulting to CODE_QA", exc)
            return Intent.CODE_QA, 0.5
