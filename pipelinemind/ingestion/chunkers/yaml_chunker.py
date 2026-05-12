"""
YAML pipeline/DAG chunker.
Parses Airflow-style DAG YAML files and extracts per-task and top-level
configuration blocks as independent chunks.
"""
from __future__ import annotations

import hashlib
import logging
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

import yaml

logger = logging.getLogger(__name__)


@dataclass
class YAMLChunk:
    chunk_id: str
    source_file: str
    chunk_type: str = "yaml"
    chunk_index: int = 0
    language: str = "yaml"
    raw_code: str = ""
    summary: str = ""
    pipeline_name: str = ""
    block_type: str = ""       # "dag_config" | "task" | "slo"
    operator_type: Optional[str] = None
    task_id: Optional[str] = None
    pii_flag: bool = False
    tags: list[str] = field(default_factory=list)
    git_commit_hash: str = ""
    content_hash: str = ""
    source_type: str = "yaml"

    def __post_init__(self) -> None:
        if not self.content_hash:
            self.content_hash = hashlib.sha256(self.raw_code.encode()).hexdigest()[:16]


class YAMLChunker:
    """Extracts pipeline config blocks from Airflow YAML DAG definitions."""

    def chunk(self, file_path: Path, git_commit_hash: str = "") -> list[YAMLChunk]:
        raw_text = file_path.read_text(encoding="utf-8")
        try:
            doc: dict[str, Any] = yaml.safe_load(raw_text)
        except yaml.YAMLError as e:
            logger.warning("YAML parse error in %s: %s", file_path, e)
            return []

        pipeline_name = doc.get("dag_id", file_path.stem)
        chunks: list[YAMLChunk] = []
        idx = 0

        # Chunk 0: top-level DAG configuration (everything except tasks)
        dag_config = {k: v for k, v in doc.items() if k != "tasks"}
        chunks.append(YAMLChunk(
            chunk_id=hashlib.sha256(f"{file_path}:dag_config".encode()).hexdigest(),
            source_file=str(file_path),
            chunk_index=idx,
            raw_code=yaml.dump(dag_config, default_flow_style=False),
            pipeline_name=pipeline_name,
            block_type="dag_config",
        ))
        idx += 1

        # Per-task chunks
        for task in doc.get("tasks", []):
            task_id = task.get("task_id", f"task_{idx}")
            chunks.append(YAMLChunk(
                chunk_id=hashlib.sha256(f"{file_path}:{task_id}".encode()).hexdigest(),
                source_file=str(file_path),
                chunk_index=idx,
                raw_code=yaml.dump(task, default_flow_style=False),
                pipeline_name=pipeline_name,
                block_type="task",
                operator_type=task.get("operator"),
                task_id=task_id,
                git_commit_hash=git_commit_hash,
            ))
            idx += 1

        # SLO block if present
        if "slo" in doc:
            chunks.append(YAMLChunk(
                chunk_id=hashlib.sha256(f"{file_path}:slo".encode()).hexdigest(),
                source_file=str(file_path),
                chunk_index=idx,
                raw_code=yaml.dump({"slo": doc["slo"]}, default_flow_style=False),
                pipeline_name=pipeline_name,
                block_type="slo",
                git_commit_hash=git_commit_hash,
            ))

        logger.debug("YAML chunker: %s → %d chunks", file_path.name, len(chunks))
        return chunks
