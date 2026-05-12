"""
AST-based Python chunker using tree-sitter.
Extracts function/method/class boundaries as independent chunks.
Falls back to whole-file chunking if tree-sitter is unavailable.
"""
from __future__ import annotations

import hashlib
import logging
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

try:
    import tree_sitter_python as tspython
    from tree_sitter import Language, Node, Parser

    _PY_LANG = Language(tspython.language())
    try:
        _PARSER: Optional[Parser] = Parser(_PY_LANG)
    except TypeError:
        _PARSER = Parser()
        _PARSER.set_language(_PY_LANG)
    _TREE_SITTER_OK = True
except Exception as _e:
    _PARSER = None
    _TREE_SITTER_OK = False
    logger.warning("tree-sitter unavailable (%s) — using regex fallback", _e)


@dataclass
class CodeChunk:
    chunk_id: str
    source_file: str
    chunk_type: str          # function | method | class | module
    chunk_index: int
    language: str = "python"
    raw_code: str = ""
    summary: str = ""        # filled later by SummaryGenerator
    function_name: Optional[str] = None
    class_name: Optional[str] = None
    decorators: list[str] = field(default_factory=list)
    return_type: Optional[str] = None
    docstring: Optional[str] = None
    line_start: int = 0
    line_end: int = 0
    pipeline_name: str = ""
    pii_flag: bool = False
    tags: list[str] = field(default_factory=list)
    git_commit_hash: str = ""
    content_hash: str = ""
    source_type: str = "python"

    def __post_init__(self) -> None:
        if not self.content_hash:
            self.content_hash = hashlib.sha256(self.raw_code.encode()).hexdigest()[:16]
        if not self.chunk_id:
            self.chunk_id = hashlib.sha256(
                f"{self.source_file}:{self.chunk_index}".encode()
            ).hexdigest()


class ASTChunker:
    """Chunks .py files at function/class boundaries via tree-sitter."""

    def chunk(self, file_path: Path, git_commit_hash: str = "") -> list[CodeChunk]:
        source = file_path.read_text(encoding="utf-8")
        pipeline_name = file_path.stem

        if _TREE_SITTER_OK and _PARSER:
            return self._tree_sitter_chunk(source, str(file_path), pipeline_name, git_commit_hash)
        return self._regex_fallback(source, str(file_path), pipeline_name, git_commit_hash)

    # ── tree-sitter path ──────────────────────────────────────────────────────

    def _tree_sitter_chunk(
        self, source: str, source_file: str, pipeline_name: str, git_commit_hash: str
    ) -> list[CodeChunk]:
        src_bytes = source.encode("utf-8")
        tree = _PARSER.parse(src_bytes)
        chunks: list[CodeChunk] = []
        idx = 0

        for node in tree.root_node.children:
            if node.type == "function_definition":
                chunks.append(self._fn_chunk(node, src_bytes, source_file, idx, pipeline_name, git_commit_hash))
                idx += 1
            elif node.type == "class_definition":
                class_chunks = self._class_chunks(node, src_bytes, source_file, idx, pipeline_name, git_commit_hash)
                chunks.extend(class_chunks)
                idx += len(class_chunks)

        if not chunks:
            chunks.append(self._module_chunk(source, source_file, pipeline_name, git_commit_hash))
        return chunks

    def _fn_chunk(self, node: "Node", src: bytes, source_file: str,
                  idx: int, pipeline: str, git_hash: str) -> CodeChunk:
        raw = src[node.start_byte:node.end_byte].decode("utf-8")
        fn_name = self._child_text(node, "identifier", src)
        return CodeChunk(
            chunk_id=hashlib.sha256(f"{source_file}:{idx}".encode()).hexdigest(),
            source_file=source_file,
            chunk_type="function",
            chunk_index=idx,
            raw_code=raw,
            function_name=fn_name,
            decorators=self._decorators(node, src),
            return_type=self._return_type(node, src),
            docstring=self._docstring(node, src),
            line_start=node.start_point[0] + 1,
            line_end=node.end_point[0] + 1,
            pipeline_name=pipeline,
            git_commit_hash=git_hash,
        )

    def _class_chunks(self, node: "Node", src: bytes, source_file: str,
                      start_idx: int, pipeline: str, git_hash: str) -> list[CodeChunk]:
        chunks: list[CodeChunk] = []
        class_name = self._child_text(node, "identifier", src)
        raw_class = src[node.start_byte:node.end_byte].decode("utf-8")

        chunks.append(CodeChunk(
            chunk_id=hashlib.sha256(f"{source_file}:{start_idx}:cls".encode()).hexdigest(),
            source_file=source_file,
            chunk_type="class",
            chunk_index=start_idx,
            raw_code=raw_class,
            class_name=class_name,
            docstring=self._docstring(node, src),
            line_start=node.start_point[0] + 1,
            line_end=node.end_point[0] + 1,
            pipeline_name=pipeline,
            git_commit_hash=git_hash,
        ))

        body = next((c for c in node.children if c.type == "block"), None)
        if body:
            for i, child in enumerate(body.children):
                if child.type == "function_definition":
                    m = self._fn_chunk(child, src, source_file, start_idx + i + 1, pipeline, git_hash)
                    m.class_name = class_name
                    m.chunk_type = "method"
                    chunks.append(m)
        return chunks

    def _module_chunk(self, source: str, source_file: str, pipeline: str, git_hash: str) -> CodeChunk:
        return CodeChunk(
            chunk_id=hashlib.sha256(source_file.encode()).hexdigest(),
            source_file=source_file,
            chunk_type="module",
            chunk_index=0,
            raw_code=source,
            pipeline_name=pipeline,
            line_start=1,
            line_end=source.count("\n") + 1,
            git_commit_hash=git_hash,
        )

    # ── helpers ──────────────────────────────────────────────────────────────

    def _child_text(self, node: "Node", child_type: str, src: bytes) -> str:
        for child in node.children:
            if child.type == child_type:
                return src[child.start_byte:child.end_byte].decode("utf-8")
        return ""

    def _docstring(self, node: "Node", src: bytes) -> Optional[str]:
        body = next((c for c in node.children if c.type == "block"), None)
        if not body:
            return None
        for child in body.children:
            if child.type == "expression_statement":
                for sub in child.children:
                    if sub.type == "string":
                        raw = src[sub.start_byte:sub.end_byte].decode("utf-8")
                        return raw.strip('"""\'').strip()
        return None

    def _decorators(self, node: "Node", src: bytes) -> list[str]:
        return [
            src[c.start_byte:c.end_byte].decode("utf-8")
            for c in node.children if c.type == "decorator"
        ]

    def _return_type(self, node: "Node", src: bytes) -> Optional[str]:
        for child in node.children:
            if child.type == "type":
                return src[child.start_byte:child.end_byte].decode("utf-8")
        return None

    # ── regex fallback ────────────────────────────────────────────────────────

    def _regex_fallback(
        self, source: str, source_file: str, pipeline: str, git_hash: str
    ) -> list[CodeChunk]:
        pattern = re.compile(r"^(def |class )", re.MULTILINE)
        lines = source.splitlines(keepends=True)
        boundaries = [m.start() for m in pattern.finditer(source)] + [len(source)]

        chunks: list[CodeChunk] = []
        for i, (start, end) in enumerate(zip(boundaries, boundaries[1:])):
            raw = source[start:end].strip()
            if not raw:
                continue
            first_line = raw.split("\n")[0]
            ctype = "function" if first_line.lstrip().startswith("def ") else "class"
            chunks.append(CodeChunk(
                chunk_id=hashlib.sha256(f"{source_file}:{i}".encode()).hexdigest(),
                source_file=source_file,
                chunk_type=ctype,
                chunk_index=i,
                raw_code=raw,
                function_name=re.search(r"(?:def|class)\s+(\w+)", first_line, re.I) and
                              re.search(r"(?:def|class)\s+(\w+)", first_line).group(1),
                pipeline_name=pipeline,
                git_commit_hash=git_hash,
            ))

        return chunks or [self._module_chunk(source, source_file, pipeline, git_hash)]
