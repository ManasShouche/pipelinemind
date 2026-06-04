"""
Cross-encoder re-ranker using ms-marco-MiniLM-L-6-v2.

Score normalisation:
  Raw cross-encoder output is an unbounded logit score.
  Positive → relevant, negative → irrelevant.
  We apply sigmoid to normalise to [0, 1] for display and confidence calculation.
  Documents with sigmoid score < 0.10 are filtered as clearly irrelevant.
"""
from __future__ import annotations

import logging
import math
from functools import lru_cache

from sentence_transformers import CrossEncoder

from pm_config import settings
from retrieval.chroma_retriever import RetrievedChunk

logger = logging.getLogger(__name__)

MODEL_NAME          = "cross-encoder/ms-marco-MiniLM-L-6-v2"
MIN_DISPLAY_SCORE   = 0.10  # sigmoid-normalised threshold — below = filtered from citations


def _sigmoid(x: float) -> float:
    """Map unbounded logit to [0, 1]."""
    return 1.0 / (1.0 + math.exp(-x))


@lru_cache(maxsize=1)
def _get_cross_encoder() -> CrossEncoder:
    logger.info("Loading cross-encoder: %s", MODEL_NAME)
    return CrossEncoder(MODEL_NAME)


class Reranker:
    """
    Re-ranks fused results using a cross-encoder.
    Raw logit scores are sigmoid-normalised before being stored on chunks
    so that downstream code always sees values in [0, 1].
    """

    def rerank(
        self,
        query: str,
        chunks: list[RetrievedChunk],
        top_k: int | None = None,
    ) -> list[RetrievedChunk]:
        if not chunks:
            return []
        if not settings.rerank_enabled:
            return chunks[: top_k or settings.top_k_rerank]

        k     = top_k or settings.top_k_rerank
        model = _get_cross_encoder()
        pairs  = [(query, c.document[:512]) for c in chunks]
        raw_scores = model.predict(pairs, show_progress_bar=False)

        for chunk, raw in zip(chunks, raw_scores):
            chunk.score             = _sigmoid(float(raw))
            chunk.retrieval_method  = "rerank"

        chunks.sort(key=lambda c: c.score, reverse=True)
        result = chunks[:k]
        for new_rank, chunk in enumerate(result):
            chunk.rank = new_rank

        top_score = result[0].score if result else 0.0
        logger.debug(
            "Re-ranked %d → %d chunks (top sigmoid_score=%.4f)",
            len(chunks), len(result), top_score,
        )
        return result
