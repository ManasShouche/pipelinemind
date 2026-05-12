"""
Intent classifier: routes queries to the correct retrieval strategy.
Uses Groq llama3-70b-8192 with a structured prompt.
Falls back to CODE_QA on any failure.
"""
from __future__ import annotations

import json
import logging
from enum import Enum

from groq import Groq
from tenacity import retry, stop_after_attempt, wait_exponential

from pm_config import settings

logger = logging.getLogger(__name__)


class Intent(str, Enum):
    CODE_QA   = "CODE_QA"    # Pipeline code understanding
    CATALOGUE = "CATALOGUE"  # Table/column/lineage queries
    HEALTH    = "HEALTH"     # Pipeline run status, SLO breaches
    ACTION    = "ACTION"     # Trigger DQ checks, impact analysis
    GENERAL   = "GENERAL"    # Generic DE education questions


_SYSTEM_PROMPT = """You are an intent classifier for a Data Engineering AI assistant.
Classify the user query into exactly one of these intents:

CODE_QA   — questions about pipeline code logic, SQL transformations, Python functions,
             configuration decisions, debugging, or implementation details.
CATALOGUE — questions about table schemas, column metadata, data lineage,
             PII classification, or data discovery.
HEALTH    — questions about pipeline run status, failures, SLO adherence,
             recent errors, or monitoring.
ACTION    — requests to trigger a DQ check, run impact analysis before a schema change,
             or execute any agentic action on the system.
GENERAL   — generic data engineering education questions with no specific pipeline context.

Respond with ONLY a JSON object: {"intent": "<INTENT>", "confidence": <0.0-1.0>}
No explanation, no markdown, no preamble."""


class IntentClassifier:
    """Classifies user queries into one of 5 retrieval intents via Groq."""

    def __init__(self) -> None:
        self._client = Groq(api_key=settings.groq_api_key)

    @retry(stop=stop_after_attempt(3), wait=wait_exponential(min=1, max=8), reraise=False)
    def classify(self, query: str) -> tuple[Intent, float]:
        """
        Returns (Intent, confidence_score).
        Falls back to CODE_QA with confidence=0.5 on any failure.
        """
        try:
            response = self._client.chat.completions.create(
                model=settings.groq_model_strong,
                messages=[
                    {"role": "system", "content": _SYSTEM_PROMPT},
                    {"role": "user",   "content": query},
                ],
                max_tokens=50,
                temperature=0.0,
            )
            raw = response.choices[0].message.content.strip()
            # Strip accidental markdown fences
            raw = raw.strip("`").strip()
            if raw.startswith("json"):
                raw = raw[4:].strip()
            parsed = json.loads(raw)
            intent_str = parsed.get("intent", "CODE_QA")
            confidence = float(parsed.get("confidence", 0.8))
            intent = Intent(intent_str)
            logger.info("Intent: %s (conf=%.2f) for '%s...'", intent, confidence, query[:60])
            return intent, confidence
        except Exception as exc:
            logger.warning("Intent classification failed (%s) — defaulting to CODE_QA", exc)
            return Intent.CODE_QA, 0.5
