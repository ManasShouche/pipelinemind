"""Unit tests for ContextBuilder."""
from __future__ import annotations

from retrieval.chroma_retriever import RetrievedChunk
from retrieval.context_builder  import ContextBuilder


def _chunk(chunk_id: str, score: float, pii: bool = False, source_type: str = "python") -> RetrievedChunk:
    return RetrievedChunk(
        chunk_id=chunk_id,
        document=f"Summary of chunk {chunk_id}",
        raw_implementation=f"def fn_{chunk_id}(): pass",
        source_file=f"pipeline/{chunk_id}.py",
        chunk_type="function",
        pipeline_name="orders",
        source_type=source_type,
        pii_flag=pii,
        tags=[],
        git_commit_hash="abc123",
        function_name=f"fn_{chunk_id}",
        class_name="",
        line_start=1,
        line_end=10,
        distance=1-score,
        score=score,
        rank=0,
    )


def test_builds_non_empty_context():
    chunks = [_chunk("a", 0.9), _chunk("b", 0.8)]
    ctx = ContextBuilder().build("test query", chunks)
    assert ctx.context_text
    assert len(ctx.chunks_used) > 0


def test_confidence_score_from_top_chunk():
    chunks = [_chunk("a", 0.85)]
    ctx = ContextBuilder().build("q", chunks)
    assert abs(ctx.confidence_score - 0.85) < 0.01


def test_low_confidence_flag():
    chunks = [_chunk("a", 0.3)]
    ctx = ContextBuilder().build("q", chunks)
    assert ctx.low_confidence


def test_pii_flag_propagated():
    chunks = [_chunk("pii_chunk", 0.9, pii=True)]
    ctx = ContextBuilder().build("q", chunks)
    assert ctx.has_pii


def test_empty_chunks_returns_fallback():
    ctx = ContextBuilder().build("q", [])
    assert ctx.confidence_score == 0.0
    assert "No relevant documents" in ctx.context_text


def test_raw_code_injected_for_python():
    chunks = [_chunk("fn", 0.9, source_type="python")]
    ctx = ContextBuilder().build("q", chunks)
    assert "def fn_fn" in ctx.context_text
