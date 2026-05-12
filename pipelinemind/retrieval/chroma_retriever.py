"""
Dense retriever: cosine similarity search over ChromaDB HNSW index.
Retrieves top-K chunks by embedding the (HyDE-processed) query.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass, field
from pathlib import Path

import chromadb

from pm_config import settings
from ingestion.embedders import ChunkEmbedder

logger = logging.getLogger(__name__)


@dataclass
class RetrievedChunk:
    chunk_id: str
    document: str          # summary text (what was embedded)
    raw_implementation: str  # full source code from metadata
    source_file: str
    chunk_type: str
    pipeline_name: str
    source_type: str
    pii_flag: bool
    tags: list[str]
    git_commit_hash: str
    function_name: str
    class_name: str
    line_start: int
    line_end: int
    distance: float = 0.0       # cosine distance (lower = more similar)
    score: float = 0.0          # 1 - distance (higher = more similar)
    rank: int = 0
    retrieval_method: str = "dense"
    metadata: dict = field(default_factory=dict)


class ChromaRetriever:
    """Semantic retrieval from the ChromaDB HNSW index."""

    COLLECTION_NAME = "pipelinemind"

    def __init__(self) -> None:
        client = chromadb.PersistentClient(path=str(settings.chroma_path))
        self.collection = client.get_or_create_collection(
            self.COLLECTION_NAME,
            metadata={"hnsw:space": "cosine"},
        )
        self.embedder = ChunkEmbedder()
        logger.info(
            "ChromaRetriever ready — collection has %d documents",
            self.collection.count(),
        )

    def retrieve(
        self,
        query: str,
        top_k: int | None = None,
        filters: dict | None = None,
    ) -> list[RetrievedChunk]:
        """
        Embed the query and retrieve the top-K most similar chunks.

        Args:
            query:   Natural language query (or HyDE hypothetical document).
            top_k:   Number of results to return. Defaults to settings.top_k_dense.
            filters: Optional ChromaDB 'where' clause for metadata filtering.
        """
        k = top_k or settings.top_k_dense
        query_vec = self.embedder.embed_query(query)

        kwargs: dict = {"query_embeddings": [query_vec], "n_results": k}
        if filters:
            kwargs["where"] = filters

        results = self.collection.query(**kwargs)
        return self._parse(results)

    def _parse(self, results: dict) -> list[RetrievedChunk]:
        chunks: list[RetrievedChunk] = []
        ids       = results.get("ids", [[]])[0]
        docs      = results.get("documents", [[]])[0]
        metas     = results.get("metadatas", [[]])[0]
        distances = results.get("distances", [[]])[0]

        for rank, (cid, doc, meta, dist) in enumerate(zip(ids, docs, metas, distances)):
            score = max(0.0, 1.0 - dist)
            chunks.append(RetrievedChunk(
                chunk_id=cid,
                document=doc,
                raw_implementation=meta.get("raw_implementation", ""),
                source_file=meta.get("source_file", ""),
                chunk_type=meta.get("chunk_type", ""),
                pipeline_name=meta.get("pipeline_name", ""),
                source_type=meta.get("source_type", ""),
                pii_flag=meta.get("pii_flag", "false").lower() == "true",
                tags=meta.get("tags", "").split(","),
                git_commit_hash=meta.get("git_commit_hash", ""),
                function_name=meta.get("function_name", ""),
                class_name=meta.get("class_name", ""),
                line_start=int(meta.get("line_start", 0)),
                line_end=int(meta.get("line_end", 0)),
                distance=dist,
                score=score,
                rank=rank,
                retrieval_method="dense",
                metadata=meta,
            ))
        return chunks
