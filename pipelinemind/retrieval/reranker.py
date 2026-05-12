"""
Cross-encoder re-ranker using ms-marco-MiniLM-L-6-v2.
Scores (query, document) pairs precisely to re-order the top-N fused results.
"""
from __future__ import annotations

import logging
from functools import lru_cache

from sentence_transformers import CrossEncoder

from pm_config import settings
from retrieval.chroma_retriever import RetrievedChunk

logger = logging.getLogger(__name__)

MODEL_NAME = "cross-encoder/ms-marco-MiniLM-L-6-v2"


@lru_cache(maxsize=1)
def _get_cross_encoder() -> CrossEncoder:
    logger.info("Loading cross-encoder: %s", MODEL_NAME)
    return CrossEncoder(MODEL_NAME)


class Reranker:
    """Re-ranks fused results using a cross-encoder for precise relevance scoring."""

    def rerank(
        self,
        query: str,
        chunks: list[RetrievedChunk],
        top_k: int | None = None,
    ) -> list[RetrievedChunk]:
        if not chunks:
            return []
        if not settings.rerank_enabled:
            return chunks[:top_k or settings.top_k_rerank]

        k = top_k or settings.top_k_rerank
        model = _get_cross_encoder()

        # Build (query, passage) pairs — prefer summary over raw_implementation for re-ranking
        pairs = [(query, c.document[:512]) for c in chunks]
        scores = model.predict(pairs, show_progress_bar=False)

        for chunk, score in zip(chunks, scores):
            chunk.score = float(score)
            chunk.retrieval_method = "rerank"

        chunks.sort(key=lambda c: c.score, reverse=True)
        result = chunks[:k]
        for new_rank, chunk in enumerate(result):
            chunk.rank = new_rank

        logger.debug("Re-ranked %d → %d chunks (top score=%.4f)", len(chunks), len(result), result[0].score if result else 0)
        return result
