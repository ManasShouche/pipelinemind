"""
Hypothetical Document Embedding (HyDE) query processor.

Model: llama3-8b-8192 via LLMRouter (was llama3-70b — overkill for doc generation).
Rationale: HyDE needs vocabulary bridging and moderate creativity, not reasoning depth.
8b generates good hypothetical documents at ~3x less quota cost than 70b.
Falls back to the original query on any failure — retrieval still works, just at
lower recall.
"""
from __future__ import annotations

import logging

from tenacity import retry, stop_after_attempt, wait_exponential

from agent.llm_router import CallType, router
from pm_config import settings

logger = logging.getLogger(__name__)

_SYSTEM_PROMPT = (
    "You are a senior data engineering architect. "
    "Given a question about a data pipeline system, generate a realistic, technical "
    "document excerpt that would be the PERFECT answer to that question. "
    "Write it as if excerpted from actual code comments, technical documentation, "
    "or pipeline configuration. Be specific about pipeline names, table names, "
    "strategies (MERGE, SCD2, etc.) where plausible. Under 200 words."
)


class HyDEProcessor:
    """
    Generates hypothetical documents for improved recall on complex queries.
    Falls back gracefully to the original query on failure.
    """

    @retry(
        stop=stop_after_attempt(3),
        wait=wait_exponential(min=1, max=10),
        reraise=False,
    )
    def generate(self, query: str) -> str:
        """
        Returns a hypothetical document string to embed in place of the raw query.
        Falls back to the original query on failure.
        """
        if not settings.hyde_enabled:
            return query
        try:
            response = router.complete(
                call_type=CallType.HYDE,
                messages=[
                    {"role": "system", "content": _SYSTEM_PROMPT},
                    {"role": "user",   "content": f"Question: {query}"},
                ],
            )
            hypo_doc = response.choices[0].message.content.strip()
            logger.debug(
                "HyDE generated %d chars (model=llama3-8b) for query: '%s...'",
                len(hypo_doc), query[:60],
            )
            return hypo_doc
        except Exception as exc:
            logger.warning("HyDE generation failed (%s) — using raw query", exc)
            return query
