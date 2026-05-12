"""
Hybrid retriever orchestrator.
Combines HyDE -> Dense -> Sparse -> RRF Fusion -> Cross-encoder Re-ranking
-> Context Builder into a single retrieve() call.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass

from pm_config import settings
from retrieval.chroma_retriever import ChromaRetriever, RetrievedChunk
from retrieval.bm25_retriever import BM25Retriever
from retrieval.rrf_fusion import reciprocal_rank_fusion
from retrieval.reranker import Reranker
from retrieval.hyde import HyDEProcessor
from retrieval.context_builder import ContextBuilder, BuiltContext
from retrieval.intent_classifier import IntentClassifier, Intent

logger = logging.getLogger(__name__)


@dataclass
class RetrievalResult:
    intent: Intent
    intent_confidence: float
    context: BuiltContext
    raw_chunks: list[RetrievedChunk]
    hyde_query: str
    original_query: str


class HybridRetriever:
    """
    Full hybrid RAG retrieval pipeline.

    Pipeline:
      1. Intent classification
      2. HyDE query expansion (if enabled)
      3. Dense retrieval (ChromaDB HNSW)
      4. Sparse retrieval (BM25)
      5. RRF fusion
      6. Cross-encoder re-ranking
      7. Context building (token budget + PII redaction + raw code injection)
    """

    def __init__(self) -> None:
        self.intent_classifier = IntentClassifier()
        self.hyde              = HyDEProcessor()
        self.dense             = ChromaRetriever()
        self.sparse            = BM25Retriever()
        self.reranker          = Reranker()
        self.context_builder   = ContextBuilder()

    def retrieve(
        self,
        query: str,
        intent_override: Intent | None = None,
        metadata_filters: dict | None = None,
    ) -> RetrievalResult:
        """Full retrieval pipeline. Returns a RetrievalResult with assembled context."""
        intent, intent_conf = (
            (intent_override, 1.0)
            if intent_override
            else self.intent_classifier.classify(query)
        )

        if intent == Intent.GENERAL:
            logger.info("GENERAL intent — skipping RAG retrieval")
            empty_ctx = BuiltContext(
                chunks_used=[],
                context_text="",
                confidence_score=1.0,
                has_pii=False,
                total_tokens_estimate=0,
                low_confidence=False,
            )
            return RetrievalResult(
                intent=intent,
                intent_confidence=intent_conf,
                context=empty_ctx,
                raw_chunks=[],
                hyde_query=query,
                original_query=query,
            )

        hyde_query = self.hyde.generate(query) if settings.hyde_enabled else query

        dense_chunks  = self.dense.retrieve(hyde_query, filters=metadata_filters)
        sparse_chunks = self.sparse.retrieve(query)

        fused_chunks  = reciprocal_rank_fusion(dense_chunks, sparse_chunks)
        ranked_chunks = self.reranker.rerank(query, fused_chunks)

        context = self.context_builder.build(query, ranked_chunks)

        logger.info(
            "Retrieval complete | intent=%s | dense=%d sparse=%d fused=%d reranked=%d "
            "| conf=%.3f | pii=%s",
            intent, len(dense_chunks), len(sparse_chunks),
            len(fused_chunks), len(ranked_chunks),
            context.confidence_score, context.has_pii,
        )
        return RetrievalResult(
            intent=intent,
            intent_confidence=intent_conf,
            context=context,
            raw_chunks=ranked_chunks,
            hyde_query=hyde_query,
            original_query=query,
        )
