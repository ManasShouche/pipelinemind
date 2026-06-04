"""
Graph RAG augmentor — enriches retrieved chunks with 1-hop lineage neighbours.

After the cross-encoder reranker, extract table-name entities from the top
chunks, walk one hop in the lineage_edges DuckDB graph, synthesize neighbour
catalogue entries as additional context chunks, and append them to the ranked
list before the context builder runs.

Only activated for CATALOGUE and ACTION intents (intent gating is the caller's
responsibility — see HybridRetriever.retrieve).
"""
from __future__ import annotations

import logging
import re
import uuid
from pathlib import Path

import duckdb

from pm_config import settings
from retrieval.chroma_retriever import RetrievedChunk

logger = logging.getLogger(__name__)

# Matches common DE table-name prefixes followed by snake_case identifiers.
_TABLE_RE = re.compile(
    r"\b(?:stg|dim|fct|vw|raw|src|int|mart|core|orders|users|sessions|revenue|events)"
    r"_[a-z][a-z0-9_]{2,40}\b",
    re.IGNORECASE,
)

# Score for graph-derived chunks: above MIN_USEFUL_SCORE (0.10) so they survive
# the context builder filter, but below typical top RAG scores so primary
# evidence always appears first in context.
_GRAPH_SCORE = 0.55
_MAX_GRAPH_CHUNKS = 3


def _extract_table_names(chunks: list[RetrievedChunk], top_n: int = 3) -> set[str]:
    """Pull candidate table names from the top-N chunks' text fields."""
    names: set[str] = set()
    for chunk in chunks[:top_n]:
        for text in (chunk.document, chunk.raw_implementation or ""):
            for m in _TABLE_RE.finditer(text):
                names.add(m.group(0).lower())
    return names


def _get_neighbour_tables(
    con: duckdb.DuckDBPyConnection,
    seed_tables: set[str],
) -> set[str]:
    """Return 1-hop upstream + downstream tables via lineage_edges."""
    if not seed_tables:
        return set()
    ph = ", ".join("?" * len(seed_tables))
    rows = con.execute(
        f"""
        SELECT DISTINCT source_table FROM lineage_edges
        WHERE target_table IN ({ph})
        UNION
        SELECT DISTINCT target_table FROM lineage_edges
        WHERE source_table IN ({ph})
        """,
        list(seed_tables) * 2,
    ).fetchall()
    return {r[0] for r in rows} - seed_tables


def _build_graph_chunk(
    con: duckdb.DuckDBPyConnection,
    table_name: str,
) -> RetrievedChunk | None:
    """Synthesize a RetrievedChunk from catalogue data for a neighbour table."""
    row = con.execute(
        "SELECT table_name, domain, description, owner FROM catalogue_tables WHERE table_name = ?",
        [table_name],
    ).fetchone()
    if not row:
        return None

    name, domain, description, owner = row

    col_rows = con.execute(
        """
        SELECT cc.column_name, cc.data_type, cc.pii_flag, cc.sensitivity_level
        FROM catalogue_columns cc
        JOIN catalogue_tables ct ON cc.table_id = ct.table_id
        WHERE ct.table_name = ?
        ORDER BY cc.column_name
        LIMIT 20
        """,
        [table_name],
    ).fetchall()

    col_lines = [
        "  - {col} ({dtype}){pii}{sens}".format(
            col=c[0], dtype=c[1],
            pii=" [PII]" if c[2] else "",
            sens=f" [{c[3]}]" if c[3] else "",
        )
        for c in col_rows
    ]
    pii_flag = any(c[2] for c in col_rows)

    doc = (
        f"[GRAPH NEIGHBOUR] Table: {name}\n"
        f"Domain: {domain or 'unknown'} | Owner: {owner or 'unknown'}\n"
        f"Description: {description or 'No description.'}\n"
        "Columns:\n"
        + ("\n".join(col_lines) if col_lines else "  (no columns indexed)")
    )

    return RetrievedChunk(
        chunk_id=f"graph_{name}_{uuid.uuid4().hex[:8]}",
        document=doc,
        raw_implementation="",
        source_file=f"catalogue/{name}",
        chunk_type="catalogue",
        pipeline_name="",
        source_type="catalogue",
        pii_flag=pii_flag,
        tags=["graph_augmented"],
        git_commit_hash="",
        function_name="",
        class_name="",
        line_start=0,
        line_end=0,
        score=_GRAPH_SCORE,
        rank=9999,
        retrieval_method="graph",
    )


class GraphAugmentor:
    """
    Appends 1-hop lineage-neighbour catalogue entries to reranked chunks.

    Usage (called by HybridRetriever for CATALOGUE / ACTION intents only):
        ranked_chunks = self.graph_augmentor.augment(ranked_chunks)
    """

    def augment(
        self,
        chunks: list[RetrievedChunk],
        *,
        db_path: Path | None = None,
    ) -> list[RetrievedChunk]:
        """
        Return chunks + graph-neighbour chunks.

        Safe to call when DuckDB is not seeded — returns chunks unchanged
        and logs a debug message rather than raising.
        """
        path = db_path or settings.duckdb_path
        if not path.exists():
            logger.debug("GraphAugmentor: DuckDB not seeded — skipping")
            return chunks

        try:
            con = duckdb.connect(str(path), read_only=True)

            seed_tables = _extract_table_names(chunks)
            if not seed_tables:
                logger.debug("GraphAugmentor: no table entities found in top chunks — skipping")
                con.close()
                return chunks

            neighbours = _get_neighbour_tables(con, seed_tables)
            logger.info(
                "GraphAugmentor | seed=%s → neighbours=%s",
                sorted(seed_tables), sorted(neighbours),
            )

            graph_chunks: list[RetrievedChunk] = []
            for tbl in sorted(neighbours)[:_MAX_GRAPH_CHUNKS]:
                gc = _build_graph_chunk(con, tbl)
                if gc:
                    graph_chunks.append(gc)

            con.close()

            if graph_chunks:
                logger.info("GraphAugmentor: appended %d graph-neighbour chunk(s)", len(graph_chunks))
            return chunks + graph_chunks

        except Exception as exc:
            logger.warning("GraphAugmentor error (non-fatal, skipping): %s", exc)
            return chunks
