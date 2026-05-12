"""
Context builder — assembles the final LLM context from re-ranked chunks.
Responsibilities:
  1. Token budget enforcement (max_context_tokens).
  2. PII column redaction from sample values before passing to LLM.
  3. Raw code injection (embed-summary/retrieve-full pattern).
  4. Confidence score computation from top chunk's cosine similarity.
"""
from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass, field

from pm_config import settings
from retrieval.chroma_retriever import RetrievedChunk

logger = logging.getLogger(__name__)

APPROX_CHARS_PER_TOKEN = 4
PII_REDACTION_PATTERN = re.compile(
    r"(email|phone|birth|ssn|password|secret|token)\s*[:=]\s*['\"]?[\w@.+\-]+['\"]?",
    re.I,
)


def _redact_pii(text: str) -> str:
    """Replace PII-like values with [REDACTED]."""
    return PII_REDACTION_PATTERN.sub(lambda m: m.group(0).split("=")[0].split(":")[0] + ": [REDACTED]", text)


def _estimate_tokens(text: str) -> int:
    return max(1, len(text) // APPROX_CHARS_PER_TOKEN)


@dataclass
class BuiltContext:
    chunks_used: list[RetrievedChunk]
    context_text: str
    confidence_score: float      # 0.0 – 1.0 based on top chunk similarity
    has_pii: bool
    total_tokens_estimate: int
    citations: list[dict] = field(default_factory=list)
    low_confidence: bool = False


class ContextBuilder:
    """
    Assembles a token-budgeted context string from re-ranked chunks.
    """

    def build(self, query: str, chunks: list[RetrievedChunk]) -> BuiltContext:
        if not chunks:
            return BuiltContext(
                chunks_used=[],
                context_text="No relevant documents found in the knowledge base.",
                confidence_score=0.0,
                has_pii=False,
                total_tokens_estimate=0,
                low_confidence=True,
            )

        budget = settings.max_context_tokens * APPROX_CHARS_PER_TOKEN
        selected: list[RetrievedChunk] = []
        used_chars = 0
        has_pii = False
        citations: list[dict] = []

        for chunk in chunks:
            # For code chunks, inject raw implementation; for others use summary
            if chunk.source_type in {"python", "sql"} and chunk.raw_implementation:
                body = chunk.raw_implementation
            else:
                body = chunk.document

            # PII redaction
            if chunk.pii_flag:
                body = _redact_pii(body)
                has_pii = True

            header = (
                f"[SOURCE {len(selected)+1}] "
                f"{chunk.source_file.split('/')[-1]} "
                f"({chunk.chunk_type}"
                + (f" | {chunk.function_name}" if chunk.function_name else "")
                + (f" | git:{chunk.git_commit_hash}" if chunk.git_commit_hash else "")
                + ")"
            )
            block = f"\n{header}\n```\n{body.strip()}\n```\n"

            if used_chars + len(block) > budget:
                logger.debug("Token budget reached at chunk %d", len(selected))
                break

            selected.append(chunk)
            used_chars += len(block)
            citations.append({
                "source_index": len(selected),
                "file": chunk.source_file,
                "chunk_type": chunk.chunk_type,
                "function_name": chunk.function_name,
                "git_commit_hash": chunk.git_commit_hash,
                "score": round(chunk.score, 4),
            })

        context_text = "\n".join(
            (
                f"[SOURCE {i+1}] "
                f"{c.source_file.split('/')[-1]} "
                f"({c.chunk_type}"
                + (f" | {c.function_name}" if c.function_name else "")
                + (f" | git:{c.git_commit_hash}" if c.git_commit_hash else "")
                + ")\n```\n"
                + (_redact_pii(c.raw_implementation or c.document) if c.pii_flag
                   else (c.raw_implementation if c.source_type in {"python","sql"} and c.raw_implementation
                         else c.document))
                + "\n```"
            )
            for i, c in enumerate(selected)
        )

        # Confidence from top-chunk score
        top_score = chunks[0].score if chunks else 0.0
        confidence = min(1.0, max(0.0, top_score))
        low_confidence = confidence < settings.confidence_threshold

        if low_confidence:
            logger.info("Low confidence retrieval (score=%.3f) for query: %s", confidence, query[:80])

        return BuiltContext(
            chunks_used=selected,
            context_text=context_text,
            confidence_score=confidence,
            has_pii=has_pii,
            total_tokens_estimate=_estimate_tokens(context_text),
            citations=citations,
            low_confidence=low_confidence,
        )
