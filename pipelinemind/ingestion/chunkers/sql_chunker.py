"""
SQL statement-level chunker.
Splits SQL files at semicolons, classifies each statement (DDL/DML/CTE),
and extracts referenced table names.
"""
from __future__ import annotations

import hashlib
import logging
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

DDL_PATTERN = re.compile(r"^\s*(CREATE|DROP|ALTER|TRUNCATE)\s+", re.I)
DML_PATTERN = re.compile(r"^\s*(INSERT|UPDATE|DELETE|MERGE)\s+", re.I)
SELECT_PATTERN = re.compile(r"^\s*(SELECT|WITH)\s+", re.I)
TABLE_REF_PATTERN = re.compile(
    r"(?:FROM|JOIN|INTO|UPDATE|MERGE\s+INTO|TABLE)\s+([`\"\[]?\w+[`\"\]]?)",
    re.I,
)


def _classify(stmt: str) -> str:
    if DDL_PATTERN.match(stmt):
        return "DDL"
    if DML_PATTERN.match(stmt):
        return "DML"
    if SELECT_PATTERN.match(stmt):
        return "SELECT"
    return "OTHER"


def _extract_tables(stmt: str) -> list[str]:
    return list({m.group(1).strip('`"[]') for m in TABLE_REF_PATTERN.finditer(stmt)})


@dataclass
class SQLChunk:
    chunk_id: str
    source_file: str
    chunk_type: str = "sql"
    chunk_index: int = 0
    language: str = "sql"
    raw_code: str = ""
    summary: str = ""
    operation_type: str = ""   # DDL | DML | SELECT | OTHER
    tables_referenced: list[str] = field(default_factory=list)
    cte_names: list[str] = field(default_factory=list)
    pipeline_name: str = ""
    pii_flag: bool = False
    tags: list[str] = field(default_factory=list)
    git_commit_hash: str = ""
    content_hash: str = ""
    source_type: str = "sql"

    def __post_init__(self) -> None:
        if not self.content_hash:
            self.content_hash = hashlib.sha256(self.raw_code.encode()).hexdigest()[:16]


class SQLChunker:
    """Splits a .sql file into per-statement chunks."""

    # ── CTE detection ─────────────────────────────────────────────────────────
    _CTE_RE = re.compile(r"\bWITH\s+(\w+)\s+AS\s*\(", re.I)

    def chunk(self, file_path: Path, git_commit_hash: str = "") -> list[SQLChunk]:
        source = file_path.read_text(encoding="utf-8")
        pipeline_name = file_path.stem
        statements = self._split_statements(source)

        chunks: list[SQLChunk] = []
        for idx, stmt in enumerate(statements):
            if not stmt.strip():
                continue
            op_type = _classify(stmt)
            cte_names = [m.group(1) for m in self._CTE_RE.finditer(stmt)]
            chunks.append(SQLChunk(
                chunk_id=hashlib.sha256(f"{file_path}:{idx}".encode()).hexdigest(),
                source_file=str(file_path),
                chunk_index=idx,
                raw_code=stmt.strip(),
                operation_type=op_type,
                tables_referenced=_extract_tables(stmt),
                cte_names=cte_names,
                pipeline_name=pipeline_name,
                git_commit_hash=git_commit_hash,
            ))

        logger.debug("SQL chunker: %s → %d statements", file_path.name, len(chunks))
        return chunks

    def _split_statements(self, source: str) -> list[str]:
        """Split on semicolons, respecting single-line comments."""
        # Strip block comments first
        source = re.sub(r"/\*.*?\*/", " ", source, flags=re.DOTALL)
        parts: list[str] = []
        current: list[str] = []
        for line in source.splitlines():
            stripped = line.strip()
            if stripped.startswith("--"):
                current.append(line)
                continue
            if ";" in line:
                # Split line at semicolon
                before, _, after = line.partition(";")
                current.append(before)
                parts.append("\n".join(current))
                current = [after] if after.strip() else []
            else:
                current.append(line)
        if current and "".join(current).strip():
            parts.append("\n".join(current))
        return parts
