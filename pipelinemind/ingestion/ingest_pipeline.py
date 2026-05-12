"""
Ingestion orchestrator — Phase 1 entry point.
Discovers files, routes to chunkers, generates summaries, embeds, and
writes to ChromaDB + BM25 index.  Supports incremental updates via SHA-256
file hash comparison.
"""
from __future__ import annotations

import hashlib
import json
import logging
import pickle
from pathlib import Path
from typing import Union

import chromadb
from rank_bm25 import BM25Okapi

from pm_config import settings
from ingestion.chunkers.ast_chunker import ASTChunker, CodeChunk
from ingestion.chunkers.sql_chunker import SQLChunker, SQLChunk
from ingestion.chunkers.yaml_chunker import YAMLChunker, YAMLChunk
from ingestion.chunkers.semantic_chunker import SemanticChunker, SemanticChunk
from ingestion.embedders import ChunkEmbedder
from ingestion.metadata_enricher import MetadataEnricher
from ingestion.summary_generator import SummaryGenerator

logging.basicConfig(level=settings.log_level, format="%(asctime)s [%(levelname)s] %(name)s — %(message)s")
logger = logging.getLogger(__name__)

AnyChunk = Union[CodeChunk, SQLChunk, YAMLChunk, SemanticChunk]

EXTENSION_MAP = {
    ".py":   "python",
    ".sql":  "sql",
    ".yml":  "yaml",
    ".yaml": "yaml",
    ".md":   "markdown",
    ".json": "json",
}

HASH_STORE_PATH = Path("./data/.file_hashes.json")


def _file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class ChromaWriter:
    """Writes enriched chunks with embeddings to a persistent ChromaDB collection."""

    COLLECTION_NAME = "pipelinemind"

    def __init__(self) -> None:
        settings.chroma_path.mkdir(parents=True, exist_ok=True)
        client = chromadb.PersistentClient(path=str(settings.chroma_path))
        self.collection = client.get_or_create_collection(
            self.COLLECTION_NAME,
            metadata={"hnsw:space": "cosine"},
        )
        logger.info("ChromaDB collection '%s' ready", self.COLLECTION_NAME)

    def upsert(self, chunks: list[AnyChunk], embeddings: list[list[float]]) -> int:
        if not chunks:
            return 0
        ids, docs, metas, embeds = [], [], [], []
        for chunk, vec in zip(chunks, embeddings):
            ids.append(chunk.chunk_id)
            docs.append(chunk.summary or chunk.raw_code[:500])
            metas.append({
                "source_file":       chunk.source_file,
                "chunk_type":        getattr(chunk, "chunk_type", "unknown"),
                "chunk_index":       chunk.chunk_index,
                "pipeline_name":     chunk.pipeline_name,
                "source_type":       getattr(chunk, "source_type", "unknown"),
                "language":          getattr(chunk, "language", ""),
                "pii_flag":          str(chunk.pii_flag),
                "tags":              ",".join(chunk.tags),
                "content_hash":      chunk.content_hash,
                "git_commit_hash":   chunk.git_commit_hash,
                "function_name":     getattr(chunk, "function_name", "") or "",
                "class_name":        getattr(chunk, "class_name", "") or "",
                "line_start":        str(getattr(chunk, "line_start", 0)),
                "line_end":          str(getattr(chunk, "line_end", 0)),
                "raw_implementation": chunk.raw_code,  # retrieve-full pattern
            })
            embeds.append(vec)

        self.collection.upsert(ids=ids, documents=docs, metadatas=metas, embeddings=embeds)
        return len(ids)


class BM25Writer:
    """Maintains a BM25 index over chunk summaries for sparse retrieval."""

    def __init__(self) -> None:
        self._corpus: list[str] = []
        self._chunk_ids: list[str] = []
        self._index: BM25Okapi | None = None

    def add(self, chunks: list[AnyChunk]) -> None:
        for chunk in chunks:
            doc = chunk.summary or chunk.raw_code[:500]
            self._corpus.append(doc)
            self._chunk_ids.append(chunk.chunk_id)
        self._index = BM25Okapi([d.lower().split() for d in self._corpus])

    def save(self) -> None:
        payload = {"corpus": self._corpus, "chunk_ids": self._chunk_ids}
        with open(settings.bm25_index_path, "wb") as fh:
            pickle.dump(payload, fh)
        logger.info("BM25 index saved: %d documents → %s", len(self._corpus), settings.bm25_index_path)


class IngestionPipeline:
    """
    Full ingestion orchestrator:
      discover → chunk → enrich → summarise → embed → ChromaDB + BM25
    """

    def __init__(self, skip_summaries: bool = False, force_reindex: bool = False) -> None:
        self.skip_summaries = skip_summaries
        self.force_reindex = force_reindex
        self.chunkers = {
            "python":   ASTChunker(),
            "sql":      SQLChunker(),
            "yaml":     YAMLChunker(),
            "markdown": SemanticChunker(),
            "json":     SemanticChunker(),
        }
        self.enricher  = MetadataEnricher()
        self.summariser = SummaryGenerator(skip_llm=skip_summaries)
        self.embedder  = ChunkEmbedder()
        self.chroma    = ChromaWriter()
        self.bm25      = BM25Writer()
        self._hashes: dict[str, str] = self._load_hashes()

    # ── hash cache ────────────────────────────────────────────────────────────

    def _load_hashes(self) -> dict[str, str]:
        if HASH_STORE_PATH.exists():
            return json.loads(HASH_STORE_PATH.read_text())
        return {}

    def _save_hashes(self) -> None:
        HASH_STORE_PATH.parent.mkdir(parents=True, exist_ok=True)
        HASH_STORE_PATH.write_text(json.dumps(self._hashes, indent=2))

    def _needs_indexing(self, path: Path) -> bool:
        if self.force_reindex:
            return True
        current = _file_sha256(path)
        if self._hashes.get(str(path)) == current:
            return False
        self._hashes[str(path)] = current
        return True

    # ── discovery ─────────────────────────────────────────────────────────────

    def _discover(self, *search_paths: str | Path) -> list[Path]:
        found: list[Path] = []
        for sp in search_paths:
            p = Path(sp)
            if p.is_file():
                found.append(p)
            elif p.is_dir():
                for ext in EXTENSION_MAP:
                    found.extend(p.rglob(f"*{ext}"))
        return [f for f in found if self._needs_indexing(f)]

    # ── run ───────────────────────────────────────────────────────────────────

    def run(
        self,
        repo_path: str | Path = "./data/pipeline_repo",
        sql_path: str | Path = "./data/sql",
        yaml_path: str | Path = "./data/dags",
        dbt_path: str | Path = "./data/dbt_project",
    ) -> dict:
        logger.info("=== PipelineMind Ingestion Started ===")
        all_files = self._discover(repo_path, sql_path, yaml_path, dbt_path)
        if not all_files:
            logger.info("No new/changed files detected — skipping ingestion")
            return {"files": 0, "chunks": 0}

        logger.info("Processing %d file(s)", len(all_files))
        all_chunks: list[AnyChunk] = []

        for file_path in all_files:
            ext = file_path.suffix.lower()
            lang = EXTENSION_MAP.get(ext, "markdown")
            chunker = self.chunkers.get(lang, self.chunkers["markdown"])
            try:
                chunks = chunker.chunk(file_path)
                chunks = self.enricher.enrich_batch(chunks)
                all_chunks.extend(chunks)
                logger.info("  %s → %d chunks", file_path.name, len(chunks))
            except Exception as exc:
                logger.error("  FAILED to chunk %s: %s", file_path, exc)

        if not all_chunks:
            logger.warning("No chunks produced — check file paths")
            return {"files": len(all_files), "chunks": 0}

        # Summarise
        logger.info("Generating summaries for %d chunks (skip_llm=%s)", len(all_chunks), self.skip_summaries)
        all_chunks = self.summariser.batch_generate(all_chunks)

        # Embed
        logger.info("Embedding %d chunks ...", len(all_chunks))
        summaries    = [c.summary or c.raw_code[:300] for c in all_chunks]
        source_types = [getattr(c, "source_type", "python") for c in all_chunks]
        embeddings   = self.embedder.embed_batch(summaries, source_types)

        # Write
        n_chroma = self.chroma.upsert(all_chunks, embeddings)
        self.bm25.add(all_chunks)
        self.bm25.save()
        self._save_hashes()

        result = {"files": len(all_files), "chunks": n_chroma}
        logger.info("=== Ingestion Complete: %d chunks across %d files ===", n_chroma, len(all_files))
        return result


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="PipelineMind ingestion pipeline")
    parser.add_argument("--repo-path",  default="./data/pipeline_repo")
    parser.add_argument("--sql-path",   default="./data/sql")
    parser.add_argument("--yaml-path",  default="./data/dags")
    parser.add_argument("--dbt-path",   default="./data/dbt_project")
    parser.add_argument("--skip-summaries", action="store_true",
                        help="Skip Groq LLM calls — use fallback summaries (faster, lower quality)")
    parser.add_argument("--force-reindex", action="store_true",
                        help="Re-index all files regardless of hash cache")
    args = parser.parse_args()

    pipeline = IngestionPipeline(
        skip_summaries=args.skip_summaries,
        force_reindex=args.force_reindex,
    )
    pipeline.run(
        repo_path=args.repo_path,
        sql_path=args.sql_path,
        yaml_path=args.yaml_path,
        dbt_path=args.dbt_path,
    )
