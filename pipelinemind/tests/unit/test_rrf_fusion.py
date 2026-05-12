"""Unit tests for Reciprocal Rank Fusion."""
from __future__ import annotations

from retrieval.chroma_retriever import RetrievedChunk
from retrieval.rrf_fusion import reciprocal_rank_fusion


def _make_chunk(chunk_id: str, score: float, method: str = "dense") -> RetrievedChunk:
    return RetrievedChunk(
        chunk_id=chunk_id, document="doc", raw_implementation="",
        source_file="f.py", chunk_type="function", pipeline_name="p",
        source_type="python", pii_flag=False, tags=[], git_commit_hash="",
        function_name="", class_name="", line_start=0, line_end=0,
        distance=1-score, score=score, rank=0, retrieval_method=method,
    )


def test_rrf_combines_both_lists():
    dense  = [_make_chunk("a", 0.9), _make_chunk("b", 0.8), _make_chunk("c", 0.7)]
    sparse = [_make_chunk("b", 0.9), _make_chunk("d", 0.8), _make_chunk("a", 0.5)]
    result = reciprocal_rank_fusion(dense, sparse, top_n=4)
    ids = [r.chunk_id for r in result]
    assert "a" in ids and "b" in ids and "c" in ids and "d" in ids


def test_rrf_document_appearing_in_both_ranks_higher():
    dense  = [_make_chunk("shared", 0.95), _make_chunk("only_dense", 0.8)]
    sparse = [_make_chunk("shared", 0.9),  _make_chunk("only_sparse", 0.85)]
    result = reciprocal_rank_fusion(dense, sparse, top_n=3)
    assert result[0].chunk_id == "shared"


def test_rrf_respects_top_n():
    dense  = [_make_chunk(str(i), 1 - i*0.1) for i in range(10)]
    sparse = [_make_chunk(str(i), 1 - i*0.1) for i in range(10)]
    result = reciprocal_rank_fusion(dense, sparse, top_n=5)
    assert len(result) <= 5


def test_rrf_empty_sparse_returns_dense_ranked():
    dense = [_make_chunk("x", 0.9), _make_chunk("y", 0.7)]
    result = reciprocal_rank_fusion(dense, [], top_n=2)
    assert len(result) == 2
