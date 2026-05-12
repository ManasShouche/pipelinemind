"""
Semantic Markdown/text chunker.
Splits at heading boundaries with a 512-token sliding window for oversized sections.
Also handles dbt manifest.json node extraction.
"""
from __future__ import annotations

import hashlib
import json
import logging
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

logger = logging.getLogger(__name__)

HEADING_RE = re.compile(r"^(#{1,6})\s+(.+)$", re.MULTILINE)
APPROX_CHARS_PER_TOKEN = 4
MAX_CHUNK_TOKENS = 512


@dataclass
class SemanticChunk:
    chunk_id: str
    source_file: str
    chunk_type: str = "markdown"
    chunk_index: int = 0
    language: str = "markdown"
    raw_code: str = ""
    summary: str = ""
    heading_level: int = 0
    section_title: str = ""
    pipeline_name: str = ""
    pii_flag: bool = False
    tags: list[str] = field(default_factory=list)
    git_commit_hash: str = ""
    content_hash: str = ""
    source_type: str = "markdown"

    def __post_init__(self) -> None:
        if not self.content_hash:
            self.content_hash = hashlib.sha256(self.raw_code.encode()).hexdigest()[:16]


class SemanticChunker:
    """Chunks Markdown at heading boundaries, with sliding window for long sections."""

    def chunk(self, file_path: Path, git_commit_hash: str = "") -> list[SemanticChunk]:
        source = file_path.read_text(encoding="utf-8")
        pipeline_name = file_path.stem

        if file_path.suffix == ".json":
            return self._chunk_json(file_path, source, pipeline_name, git_commit_hash)

        return self._chunk_markdown(source, str(file_path), pipeline_name, git_commit_hash)

    def _chunk_markdown(
        self, source: str, source_file: str, pipeline_name: str, git_hash: str
    ) -> list[SemanticChunk]:
        matches = list(HEADING_RE.finditer(source))
        if not matches:
            return [SemanticChunk(
                chunk_id=hashlib.sha256(source_file.encode()).hexdigest(),
                source_file=source_file,
                chunk_index=0,
                raw_code=source[:MAX_CHUNK_TOKENS * APPROX_CHARS_PER_TOKEN],
                pipeline_name=pipeline_name,
                git_commit_hash=git_hash,
            )]

        boundaries = [m.start() for m in matches] + [len(source)]
        chunks: list[SemanticChunk] = []
        for i, (match, start, end) in enumerate(
            zip(matches, boundaries, boundaries[1:])
        ):
            section_text = source[start:end].strip()
            level = len(match.group(1))
            title = match.group(2).strip()
            # sliding window for oversized sections
            sub_chunks = self._sliding_window(section_text)
            for j, window in enumerate(sub_chunks):
                chunks.append(SemanticChunk(
                    chunk_id=hashlib.sha256(f"{source_file}:{i}:{j}".encode()).hexdigest(),
                    source_file=source_file,
                    chunk_index=len(chunks),
                    raw_code=window,
                    heading_level=level,
                    section_title=title,
                    pipeline_name=pipeline_name,
                    git_commit_hash=git_hash,
                ))
        logger.debug("Markdown chunker: %s → %d chunks", Path(source_file).name, len(chunks))
        return chunks

    def _sliding_window(self, text: str) -> list[str]:
        max_chars = MAX_CHUNK_TOKENS * APPROX_CHARS_PER_TOKEN
        if len(text) <= max_chars:
            return [text]
        windows: list[str] = []
        start = 0
        step = int(max_chars * 0.75)
        while start < len(text):
            windows.append(text[start:start + max_chars])
            start += step
        return windows

    def _chunk_json(
        self, file_path: Path, source: str, pipeline_name: str, git_hash: str
    ) -> list[SemanticChunk]:
        """Extract dbt manifest.json model nodes as individual chunks."""
        try:
            doc = json.loads(source)
        except json.JSONDecodeError:
            return []

        chunks: list[SemanticChunk] = []
        for i, (node_id, node) in enumerate(doc.get("nodes", {}).items()):
            text = (
                f"Model: {node.get('name', '')}\n"
                f"Description: {node.get('description', '')}\n"
                f"Materialization: {node.get('config', {}).get('materialized', '')}\n"
                f"Tags: {', '.join(node.get('tags', []))}\n"
                f"Depends on: {', '.join(node.get('depends_on', {}).get('nodes', []))}\n"
                f"Columns: {json.dumps(node.get('columns', {}), indent=2)}"
            )
            chunks.append(SemanticChunk(
                chunk_id=hashlib.sha256(f"{file_path}:{node_id}".encode()).hexdigest(),
                source_file=str(file_path),
                chunk_type="dbt_model",
                chunk_index=i,
                raw_code=text,
                section_title=node.get("name", node_id),
                pipeline_name=node.get("name", pipeline_name),
                tags=node.get("tags", []),
                git_commit_hash=git_hash,
                source_type="dbt",
            ))
        logger.debug("dbt manifest chunker: %s → %d model nodes", file_path.name, len(chunks))
        return chunks
