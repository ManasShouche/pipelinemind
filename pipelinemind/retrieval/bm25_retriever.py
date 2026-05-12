"""
Sparse BM25 retriever.
Loads the pickled BM25Okapi index built during ingestion and retrieves
top-K chunks by keyword relevance.  Uses the same RetrievedChunk type
for uniform fusion downstream.
"""
from __future__ import annotations

import logging
import pickle
from pathlib import Path

from rank_bm25 import BM25Okapi

from pm_config import settings
from retrieval.chroma_retriever import RetrievedChunk

logger = logging.getLogger(__name__)


class BM25Retriever:
    """Sparse keyword retrieval using BM25Okapi."""

    def __init__(self) -> None:
        self._index: BM25Okapi | None = None
        self._corpus: list[str] = []
        self._chunk_ids: list[str] = []
        self._load()

    def _load(self) -> None:
        path = settings.bm25_index_path
        if not path.exists():
            logger.warning("BM25 index not found at %s — sparse retrieval disabled", path)
            return
        with open(path, "rb") as fh:
            payload = pickle.load(fh)
        self._corpus    = payload["corpus"]
        self._chunk_ids = payload["chunk_ids"]
        self._index     = BM25Okapi([doc.lower().split() for doc in self._corpus])
        logger.info("BM25 index loaded: %d documents", len(self._corpus))

    @property
    def available(self) -> bool:
        return self._index is not None

    def retrieve(self, query: str, top_k: int | None = None) -> list[RetrievedChunk]:
        if not self.available:
            logger.warning("BM25 index not available — returning empty results")
            return []

        k = top_k or settings.top_k_sparse
        tokens = query.lower().split()
        scores = self._index.get_scores(tokens)  # type: ignore[union-attr]

        # Rank by score descending
        ranked_idx = sorted(range(len(scores)), key=lambda i: scores[i], reverse=True)[:k]

        chunks: list[RetrievedChunk] = []
        max_score = float(scores[ranked_idx[0]]) if ranked_idx else 1.0
        for rank, idx in enumerate(ranked_idx):
            raw_score = float(scores[idx])
            norm_score = raw_score / max_score if max_score > 0 else 0.0
            chunks.append(RetrievedChunk(
                chunk_id=self._chunk_ids[idx],
                document=self._corpus[idx],
                raw_implementation="",  # BM25 does not carry metadata
                source_file="",
                chunk_type="",
                pipeline_name="",
                source_type="",
                pii_flag=False,
                tags=[],
                git_commit_hash="",
                function_name="",
                class_name="",
                line_start=0,
                line_end=0,
                distance=1.0 - norm_score,
                score=norm_score,
                rank=rank,
                retrieval_method="sparse",
            ))
        return chunks
