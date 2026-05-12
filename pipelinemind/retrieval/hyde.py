"""
Hypothetical Document Embedding (HyDE) query processor.
Generates a hypothetical answer to the query using Groq, then embeds
the hypothetical answer rather than the raw query.  This bridges the
vocabulary gap between natural language questions and technical documents.
"""
from __future__ import annotations

import logging

from groq import Groq
from tenacity import retry, stop_after_attempt, wait_exponential

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
    Falls back to the original query on any Groq failure.
    """

    def __init__(self) -> None:
        self._client = Groq(api_key=settings.groq_api_key)

    @retry(stop=stop_after_attempt(3), wait=wait_exponential(min=1, max=10), reraise=False)
    def generate(self, query: str) -> str:
        """
        Returns a hypothetical document string to embed in place of the raw query.
        Falls back gracefully to the original query on failure.
        """
        if not settings.hyde_enabled:
            return query
        try:
            response = self._client.chat.completions.create(
                model=settings.groq_model_strong,
                messages=[
                    {"role": "system", "content": _SYSTEM_PROMPT},
                    {"role": "user",   "content": f"Question: {query}"},
                ],
                max_tokens=250,
                temperature=0.4,
            )
            hypo_doc = response.choices[0].message.content.strip()
            logger.debug("HyDE generated %d chars for query: '%s...'", len(hypo_doc), query[:60])
            return hypo_doc
        except Exception as exc:
            logger.warning("HyDE generation failed (%s) — using raw query", exc)
            return query
