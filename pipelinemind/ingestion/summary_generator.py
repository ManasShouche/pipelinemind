"""
LLM-powered chunk summary generator.
Uses Groq llama3-8b-8192 (fast/cheap) to generate natural language summaries
for each code/config chunk.  These summaries are embedded for retrieval
(embed-summary/retrieve-full pattern).
"""
from __future__ import annotations

import logging
import time
from typing import Union

from groq import Groq, RateLimitError, APIError
from tenacity import retry, stop_after_attempt, wait_exponential, retry_if_exception_type

from pm_config import settings
from ingestion.chunkers.ast_chunker import CodeChunk
from ingestion.chunkers.sql_chunker import SQLChunk
from ingestion.chunkers.yaml_chunker import YAMLChunk
from ingestion.chunkers.semantic_chunker import SemanticChunk

logger = logging.getLogger(__name__)

AnyChunk = Union[CodeChunk, SQLChunk, YAMLChunk, SemanticChunk]

SUMMARY_PROMPTS: dict[str, str] = {
    "function": (
        "Summarise this Python function for a data engineering assistant. "
        "Include: what it does, its parameters, return value, side effects, and "
        "any pipeline or ETL patterns it implements. Under 120 words."
    ),
    "method": (
        "Summarise this Python class method. Include the class context if visible, "
        "what the method does, its parameters, return value. Under 100 words."
    ),
    "class": (
        "Summarise this Python class for a data engineering context. "
        "Include: class purpose, main methods, ETL or pipeline role. Under 120 words."
    ),
    "module": (
        "Summarise this Python module. Include: overall purpose, key classes/functions, "
        "data pipeline role. Under 150 words."
    ),
    "sql": (
        "Summarise this SQL statement for a data engineering assistant. "
        "Include: operation type (DDL/DML/SELECT), tables involved, purpose, "
        "any joins or aggregations. Under 100 words."
    ),
    "yaml": (
        "Summarise this Airflow DAG or task configuration block. "
        "Include: DAG/task ID, schedule, operator type, dependencies. Under 80 words."
    ),
    "markdown": (
        "Summarise this documentation section. Include the main topic and key points. Under 80 words."
    ),
    "dbt_model": (
        "Summarise this dbt model. Include: model name, description, materialization strategy, "
        "upstream dependencies, and downstream consumers. Under 100 words."
    ),
}

_FALLBACK_PREFIX = "[AUTO-SUMMARY] "


class SummaryGenerator:
    """
    Generates natural-language summaries via Groq for the embed-summary pattern.
    Includes retry logic, rate-limit awareness, and graceful degradation.
    """

    def __init__(self, skip_llm: bool = False) -> None:
        self.skip_llm = skip_llm
        self._client: Groq | None = None
        if not skip_llm:
            self._client = Groq(api_key=settings.groq_api_key)

    @property
    def client(self) -> Groq:
        if self._client is None:
            raise RuntimeError("Groq client not initialised (skip_llm=True)")
        return self._client

    def generate(self, chunk: AnyChunk) -> str:
        """Generate a summary for a single chunk.  Returns empty string on failure."""
        if self.skip_llm:
            return self._fallback_summary(chunk)
        try:
            return self._call_llm(chunk)
        except Exception as exc:
            logger.warning("Summary generation failed for %s: %s — using fallback", chunk.chunk_id, exc)
            return self._fallback_summary(chunk)

    @retry(
        retry=retry_if_exception_type((RateLimitError, APIError)),
        stop=stop_after_attempt(4),
        wait=wait_exponential(multiplier=1, min=2, max=30),
        reraise=True,
    )
    def _call_llm(self, chunk: AnyChunk) -> str:
        ctype = getattr(chunk, "chunk_type", "module")
        prompt_instruction = SUMMARY_PROMPTS.get(ctype, SUMMARY_PROMPTS["module"])
        raw_code = chunk.raw_code[:3000]  # cap to avoid token overflow

        response = self.client.chat.completions.create(
            model=settings.groq_model_fast,
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
            max_tokens=200,
            temperature=0.1,
        )
        summary = response.choices[0].message.content.strip()
        time.sleep(0.3)  # polite rate-limit buffer
        return summary

    def _fallback_summary(self, chunk: AnyChunk) -> str:
        """Deterministic summary from code metadata when LLM is unavailable."""
        name = (
            getattr(chunk, "function_name", None)
            or getattr(chunk, "class_name", None)
            or getattr(chunk, "task_id", None)
            or getattr(chunk, "section_title", None)
            or chunk.source_file.split("/")[-1]
        )
        ctype = getattr(chunk, "chunk_type", "code")
        docstring = getattr(chunk, "docstring", None) or ""
        snippet = chunk.raw_code[:200].replace("\n", " ")
        return f"{_FALLBACK_PREFIX}{ctype} '{name}': {docstring or snippet}"

    def batch_generate(self, chunks: list[AnyChunk], batch_size: int = 10) -> list[AnyChunk]:
        """Generate summaries for a list of chunks in batches, mutating each chunk."""
        total = len(chunks)
        for i, chunk in enumerate(chunks):
            chunk.summary = self.generate(chunk)
            if (i + 1) % batch_size == 0:
                logger.info("Summarised %d / %d chunks", i + 1, total)
        logger.info("Summary generation complete: %d chunks", total)
        return chunks
