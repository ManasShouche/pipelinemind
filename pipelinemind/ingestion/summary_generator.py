"""
LLM-powered chunk summary generator.
Uses LLMRouter → llama3-8b-8192 for fast/cheap summaries at ingestion time.
These summaries are embedded for retrieval (embed-summary/retrieve-full pattern).
"""
from __future__ import annotations

import logging
import time
from typing import Union

from groq import RateLimitError, APIError
from tenacity import retry, stop_after_attempt, wait_exponential, retry_if_exception_type

from agent.llm_router import CallType, router
from ingestion.chunkers.ast_chunker import CodeChunk
from ingestion.chunkers.sql_chunker import SQLChunk
from ingestion.chunkers.yaml_chunker import YAMLChunk
from ingestion.chunkers.semantic_chunker import SemanticChunk

logger = logging.getLogger(__name__)

AnyChunk = Union[CodeChunk, SQLChunk, YAMLChunk, SemanticChunk]

SUMMARY_PROMPTS: dict[str, str] = {
    "function": (
        "Summarise this Python function for a data engineering assistant. "
        "Include: what it does, parameters, return value, side effects, and "
        "pipeline/ETL patterns it implements. Under 120 words."
    ),
    "method": (
        "Summarise this Python class method. Include class context if visible, "
        "what the method does, parameters, return value. Under 100 words."
    ),
    "class": (
        "Summarise this Python class in a data engineering context. "
        "Include: purpose, main methods, ETL or pipeline role. Under 120 words."
    ),
    "module": (
        "Summarise this Python module. Include: purpose, key classes/functions, "
        "data pipeline role. Under 150 words."
    ),
    "sql": (
        "Summarise this SQL statement. Include: operation type (DDL/DML/SELECT), "
        "tables involved, purpose, any joins or aggregations. Under 100 words."
    ),
    "yaml": (
        "Summarise this Airflow DAG or task configuration block. "
        "Include: DAG/task ID, schedule, operator type, dependencies. Under 80 words."
    ),
    "markdown": (
        "Summarise this documentation section. Include main topic and key points. Under 80 words."
    ),
    "dbt_model": (
        "Summarise this dbt model. Include: name, description, materialization, "
        "upstream dependencies, downstream consumers. Under 100 words."
    ),
}

_FALLBACK_PREFIX = "[AUTO-SUMMARY] "


class SummaryGenerator:
    """
    Generates natural-language summaries via LLMRouter (llama3-8b).
    Includes retry logic, rate-limit awareness, and graceful degradation.
    """

    def __init__(self, skip_llm: bool = False) -> None:
        self.skip_llm = skip_llm

    def generate(self, chunk: AnyChunk) -> str:
        if self.skip_llm:
            return self._fallback_summary(chunk)
        try:
            return self._call_llm(chunk)
        except Exception as exc:
            logger.warning(
                "Summary generation failed for %s: %s — using fallback",
                chunk.chunk_id, exc,
            )
            return self._fallback_summary(chunk)

    @retry(
        retry=retry_if_exception_type((RateLimitError, APIError)),
        stop=stop_after_attempt(4),
        wait=wait_exponential(multiplier=1, min=2, max=30),
        reraise=True,
    )
    def _call_llm(self, chunk: AnyChunk) -> str:
        ctype             = getattr(chunk, "chunk_type", "module")
        prompt_instruction = SUMMARY_PROMPTS.get(ctype, SUMMARY_PROMPTS["module"])
        raw_code          = chunk.raw_code[:3000]

        response = router.complete(
            call_type=CallType.SUMMARY,
            messages=[
                {
                    "role": "system",
                    "content": (
                        "You are a senior data engineering assistant. "
                        "Write concise, accurate technical summaries. "
                        "Do not include preamble or meta-commentary."
                    ),
                },
                {
                    "role": "user",
                    "content": f"{prompt_instruction}\n\n```\n{raw_code}\n```",
                },
            ],
        )
        summary = response.choices[0].message.content.strip()
        time.sleep(0.3)  # polite rate-limit buffer
        return summary

    def _fallback_summary(self, chunk: AnyChunk) -> str:
        name = (
            getattr(chunk, "function_name", None)
            or getattr(chunk, "class_name", None)
            or getattr(chunk, "task_id", None)
            or getattr(chunk, "section_title", None)
            or chunk.source_file.split("/")[-1]
        )
        ctype     = getattr(chunk, "chunk_type", "code")
        docstring = getattr(chunk, "docstring", None) or ""
        snippet   = chunk.raw_code[:200].replace("\n", " ")
        return f"{_FALLBACK_PREFIX}{ctype} '{name}': {docstring or snippet}"

    def batch_generate(self, chunks: list[AnyChunk], batch_size: int = 10) -> list[AnyChunk]:
        total = len(chunks)
        for i, chunk in enumerate(chunks):
            chunk.summary = self.generate(chunk)
            if (i + 1) % batch_size == 0:
                logger.info("Summarised %d / %d chunks", i + 1, total)
        logger.info("Summary generation complete: %d chunks", total)
        return chunks
