"""
Reciprocal Rank Fusion (RRF) for combining dense and sparse result lists.
RRF(d) = sum_over_rankers[ 1 / (k + rank(d)) ]
k=60 is the standard constant that smooths rank differences.
"""
from __future__ import annotations

import logging
from collections import defaultdict

from pm_config import settings
from retrieval.chroma_retriever import RetrievedChunk

logger = logging.getLogger(__name__)


def reciprocal_rank_fusion(
    dense_results:  list[RetrievedChunk],
    sparse_results: list[RetrievedChunk],
    k: int | None = None,
    top_n: int | None = None,
) -> list[RetrievedChunk]:
    """
    Fuse two ranked lists using Reciprocal Rank Fusion.

    Args:
        dense_results:  Ranked list from ChromaDB dense retrieval.
        sparse_results: Ranked list from BM25 sparse retrieval.
        k:              RRF smoothing constant (default: settings.rrf_k = 60).
        top_n:          Number of results to return after fusion.

    Returns:
        Fused list sorted by RRF score descending.
    """
    rrf_k  = k    or settings.rrf_k
    top_n  = top_n or settings.top_k_fused
    rrf_scores: dict[str, float] = defaultdict(float)

    # Build a lookup of chunk_id → chunk object (prefer dense as it has more metadata)
    chunk_lookup: dict[str, RetrievedChunk] = {}

    for rank, chunk in enumerate(dense_results):
        rrf_scores[chunk.chunk_id] += 1.0 / (rrf_k + rank + 1)
        chunk_lookup[chunk.chunk_id] = chunk

    for rank, chunk in enumerate(sparse_results):
        rrf_scores[chunk.chunk_id] += 1.0 / (rrf_k + rank + 1)
        # Only store sparse chunk if not already captured from dense
        if chunk.chunk_id not in chunk_lookup:
            chunk_lookup[chunk.chunk_id] = chunk

    # Sort by fused score
    ranked_ids = sorted(rrf_scores, key=lambda cid: rrf_scores[cid], reverse=True)[:top_n]

    fused: list[RetrievedChunk] = []
    for new_rank, cid in enumerate(ranked_ids):
        chunk = chunk_lookup[cid]
        chunk.score = rrf_scores[cid]
        chunk.rank  = new_rank
        chunk.retrieval_method = "rrf"
        fused.append(chunk)

    logger.debug(
        "RRF fusion: dense=%d sparse=%d → fused=%d (k=%d)",
        len(dense_results), len(sparse_results), len(fused), rrf_k,
    )
    return fused
