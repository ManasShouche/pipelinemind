"""
Metadata enricher: attaches PII flags, pipeline tags, and git commit hash
to each chunk before it is written to ChromaDB.
"""
from __future__ import annotations

import json
import logging
import subprocess
from pathlib import Path
from typing import Union

from ingestion.chunkers.ast_chunker import CodeChunk
from ingestion.chunkers.sql_chunker import SQLChunk
from ingestion.chunkers.yaml_chunker import YAMLChunk
from ingestion.chunkers.semantic_chunker import SemanticChunk

logger = logging.getLogger(__name__)

AnyChunk = Union[CodeChunk, SQLChunk, YAMLChunk, SemanticChunk]

# Load PII registry at module import (cheap, ~6 rows)
_PII_REGISTRY: dict[str, set[str]] = {}

def _load_pii_registry(pii_json_path: Path | None = None) -> None:
    global _PII_REGISTRY
    if pii_json_path is None:
        pii_json_path = Path(__file__).parent.parent / "data" / "catalogue" / "pii_registry.json"
    if not pii_json_path.exists():
        logger.warning("PII registry not found at %s", pii_json_path)
        return
    rows = json.loads(pii_json_path.read_text())
    for row in rows:
        table = row["table_name"]
        col = row["column_name"]
        _PII_REGISTRY.setdefault(table, set()).add(col)
    logger.info("PII registry loaded: %d tables", len(_PII_REGISTRY))


def _get_git_hash(file_path: Path) -> str:
    """Return the latest git commit hash for a file, or empty string on failure."""
    try:
        result = subprocess.run(
            ["git", "log", "-1", "--format=%H", "--", str(file_path)],
            capture_output=True, text=True, timeout=5,
            cwd=file_path.parent,
        )
        return result.stdout.strip()[:12] or ""
    except Exception:
        return ""


def _is_pii(chunk: AnyChunk) -> bool:
    """Determine if a chunk references PII-tagged columns."""
    pipeline = getattr(chunk, "pipeline_name", "").lower()
    raw = chunk.raw_code.lower()
    for table, cols in _PII_REGISTRY.items():
        if table.lower() in raw or table.lower() in pipeline:
            for col in cols:
                if col.lower() in raw:
                    return True
    return False


class MetadataEnricher:
    """Attaches git hashes, PII flags, and tags to chunks in-place."""

    def __init__(self) -> None:
        _load_pii_registry()

    def enrich(self, chunk: AnyChunk) -> AnyChunk:
        # Git hash
        if not chunk.git_commit_hash:
            chunk.git_commit_hash = _get_git_hash(Path(chunk.source_file))

        # PII flag
        chunk.pii_flag = _is_pii(chunk)

        # Tags — ensure source_type tag is present
        st = getattr(chunk, "source_type", "unknown")
        if st not in chunk.tags:
            chunk.tags.append(st)
        if chunk.pii_flag and "pii" not in chunk.tags:
            chunk.tags.append("pii")

        return chunk

    def enrich_batch(self, chunks: list[AnyChunk]) -> list[AnyChunk]:
        return [self.enrich(c) for c in chunks]
