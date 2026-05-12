"""Unit tests for all chunker modules."""
from __future__ import annotations

import tempfile
from pathlib import Path

import pytest

from ingestion.chunkers.ast_chunker    import ASTChunker
from ingestion.chunkers.sql_chunker    import SQLChunker
from ingestion.chunkers.yaml_chunker   import YAMLChunker
from ingestion.chunkers.semantic_chunker import SemanticChunker


PYTHON_SAMPLE = '''
def extract(watermark: str) -> list:
    """Pull records since watermark."""
    return []

class OrdersPipeline:
    """Handles orders ETL."""

    def run(self) -> dict:
        """Execute the pipeline."""
        return {"status": "success"}
'''

SQL_SAMPLE = '''
CREATE TABLE orders_fact (
    order_id VARCHAR(36) PRIMARY KEY,
    total_amount NUMERIC(12,2)
);

SELECT order_id, SUM(total_amount) AS total
FROM orders_fact
WHERE status_code >= 1
GROUP BY order_id;
'''

YAML_SAMPLE = '''
dag_id: test_dag
description: Test pipeline
schedule_interval: "0 * * * *"
tasks:
  - task_id: run_pipeline
    operator: PythonOperator
    python_callable: "pipeline.run"
slo:
  success_rate_target_pct: 99.0
'''

MARKDOWN_SAMPLE = '''
# Orders Pipeline

The orders pipeline processes all confirmed orders.

## Extract Phase

Reads from the OLTP database using a watermark strategy.

## Load Phase

Uses MERGE to upsert into the warehouse.
'''


def _write_temp(suffix: str, content: str) -> Path:
    tmp = tempfile.NamedTemporaryFile(suffix=suffix, delete=False, mode="w")
    tmp.write(content)
    tmp.flush()
    return Path(tmp.name)


class TestASTChunker:
    def test_produces_chunks(self):
        path = _write_temp(".py", PYTHON_SAMPLE)
        chunks = ASTChunker().chunk(path)
        assert len(chunks) >= 1, "Should produce at least one chunk"

    def test_function_chunk_has_name(self):
        path = _write_temp(".py", PYTHON_SAMPLE)
        chunks = ASTChunker().chunk(path)
        fn_chunks = [c for c in chunks if c.chunk_type in ("function", "method")]
        assert any(c.function_name for c in fn_chunks)

    def test_chunk_has_required_fields(self):
        path = _write_temp(".py", PYTHON_SAMPLE)
        chunks = ASTChunker().chunk(path)
        for c in chunks:
            assert c.chunk_id
            assert c.raw_code
            assert c.source_file

    def test_content_hash_is_stable(self):
        path = _write_temp(".py", PYTHON_SAMPLE)
        chunks1 = ASTChunker().chunk(path)
        chunks2 = ASTChunker().chunk(path)
        hashes1 = [c.content_hash for c in chunks1]
        hashes2 = [c.content_hash for c in chunks2]
        assert hashes1 == hashes2


class TestSQLChunker:
    def test_splits_statements(self):
        path = _write_temp(".sql", SQL_SAMPLE)
        chunks = SQLChunker().chunk(path)
        assert len(chunks) >= 2

    def test_classifies_ddl(self):
        path = _write_temp(".sql", SQL_SAMPLE)
        chunks = SQLChunker().chunk(path)
        ops = [c.operation_type for c in chunks]
        assert "DDL" in ops

    def test_extracts_table_refs(self):
        path = _write_temp(".sql", SQL_SAMPLE)
        chunks = SQLChunker().chunk(path)
        all_tables = [t for c in chunks for t in c.tables_referenced]
        assert "orders_fact" in all_tables


class TestYAMLChunker:
    def test_produces_dag_config_chunk(self):
        path = _write_temp(".yml", YAML_SAMPLE)
        chunks = YAMLChunker().chunk(path)
        block_types = [c.block_type for c in chunks]
        assert "dag_config" in block_types

    def test_produces_task_chunks(self):
        path = _write_temp(".yml", YAML_SAMPLE)
        chunks = YAMLChunker().chunk(path)
        task_chunks = [c for c in chunks if c.block_type == "task"]
        assert len(task_chunks) >= 1

    def test_extracts_pipeline_name(self):
        path = _write_temp(".yml", YAML_SAMPLE)
        chunks = YAMLChunker().chunk(path)
        assert all(c.pipeline_name == "test_dag" for c in chunks)


class TestSemanticChunker:
    def test_chunks_by_heading(self):
        path = _write_temp(".md", MARKDOWN_SAMPLE)
        chunks = SemanticChunker().chunk(path)
        assert len(chunks) >= 2

    def test_heading_metadata(self):
        path = _write_temp(".md", MARKDOWN_SAMPLE)
        chunks = SemanticChunker().chunk(path)
        titled = [c for c in chunks if c.section_title]
        assert len(titled) >= 1
