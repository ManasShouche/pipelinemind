"""
Dual embedding strategy:
  - all-mpnet-base-v2  → documents, YAML, Markdown, dbt nodes  (768-dim)
  - CodeBERT (via ST)  → Python / SQL code chunks               (768-dim)
Both produce 768-dimensional embeddings for a unified ChromaDB collection.
"""
from __future__ import annotations

import logging
from functools import lru_cache
from pathlib import Path
from typing import Union

import numpy as np
from sentence_transformers import SentenceTransformer
from sentence_transformers.sentence_transformer import modules as st_modules

from pm_config import settings

logger = logging.getLogger(__name__)

CODE_SOURCE_TYPES = {"python", "sql"}
TEXT_MODEL_NAME = "sentence-transformers/all-mpnet-base-v2"
CODE_MODEL_BASE = "microsoft/codebert-base"
EMBED_DIM = 768


@lru_cache(maxsize=1)
def _get_text_embedder() -> SentenceTransformer:
    logger.info("Loading text embedder: %s", TEXT_MODEL_NAME)
    return SentenceTransformer(
        TEXT_MODEL_NAME,
        cache_folder=str(settings.embed_cache_dir),
    )


@lru_cache(maxsize=1)
def _get_code_embedder() -> SentenceTransformer:
    """Build CodeBERT as a SentenceTransformer with mean pooling."""
    logger.info("Loading code embedder: %s", CODE_MODEL_BASE)
    cache = str(settings.embed_cache_dir)
    word_model = st_modules.Transformer(CODE_MODEL_BASE, cache_dir=cache)
    pool_model = st_modules.Pooling(
        word_model.get_word_embedding_dimension(),
        pooling_mode_mean_tokens=True,
    )
    return SentenceTransformer(modules=[word_model, pool_model])


class ChunkEmbedder:
    """
    Routes chunks to the appropriate embedding model based on source_type,
    then returns normalised 768-dim float vectors.
    """

    def embed_chunk(self, summary: str, source_type: str = "python") -> list[float]:
        """Embed a single chunk summary.  source_type routes model selection."""
        embedder = _get_code_embedder() if source_type in CODE_SOURCE_TYPES else _get_text_embedder()
        vector: np.ndarray = embedder.encode(summary, normalize_embeddings=True, show_progress_bar=False)
        return vector.tolist()

    def embed_batch(
        self, summaries: list[str], source_types: list[str], batch_size: int = 64
    ) -> list[list[float]]:
        """
        Embed a batch of summaries.  Groups by model to minimise model-switching overhead.
        Returns a list of vectors in the same order as input.
        """
        if not summaries:
            return []

        code_idx = [i for i, st in enumerate(source_types) if st in CODE_SOURCE_TYPES]
        text_idx = [i for i, st in enumerate(source_types) if st not in CODE_SOURCE_TYPES]

        result: list[list[float]] = [[]] * len(summaries)

        if code_idx:
            code_summaries = [summaries[i] for i in code_idx]
            code_vecs = _get_code_embedder().encode(
                code_summaries, normalize_embeddings=True,
                batch_size=batch_size, show_progress_bar=True
            )
            for i, vec in zip(code_idx, code_vecs):
                result[i] = vec.tolist()

        if text_idx:
            text_summaries = [summaries[i] for i in text_idx]
            text_vecs = _get_text_embedder().encode(
                text_summaries, normalize_embeddings=True,
                batch_size=batch_size, show_progress_bar=True
            )
            for i, vec in zip(text_idx, text_vecs):
                result[i] = vec.tolist()

        return result

    def embed_query(self, query: str) -> list[float]:
        """Embed a user query using the text embedder (queries are natural language)."""
        vec: np.ndarray = _get_text_embedder().encode(
            query, normalize_embeddings=True, show_progress_bar=False
        )
        return vec.tolist()
