"""
Data catalogue REST endpoints.
"""
from __future__ import annotations

import logging

import duckdb
from fastapi import APIRouter, HTTPException

from agent.tools.lineage_tools   import get_lineage_graph
from agent.tools.catalogue_tools import search_pii_tables
from pm_config import settings

logger = logging.getLogger(__name__)
router = APIRouter()


@router.get("/catalogue/tables")
async def list_tables():
    con = duckdb.connect(str(settings.duckdb_path), read_only=True)
    rows = con.execute(
        "SELECT table_id, table_name, schema_name, description, domain, pii_flag, tags, row_count "
        "FROM catalogue_tables ORDER BY table_name"
    ).fetchall()
    con.close()
    return [
        {"table_id": r[0], "table_name": r[1], "schema": r[2], "description": r[3],
         "domain": r[4], "pii_flag": r[5], "tags": r[6], "row_count": r[7]}
        for r in rows
    ]


@router.get("/catalogue/tables/{table_name}")
async def table_detail(table_name: str):
    con = duckdb.connect(str(settings.duckdb_path), read_only=True)
    tbl = con.execute(
        "SELECT * FROM catalogue_tables WHERE table_name = ?", [table_name]
    ).fetchone()
    if not tbl:
        raise HTTPException(status_code=404, detail=f"Table '{table_name}' not found")
    cols = con.execute(
        """
        SELECT cc.column_name, cc.data_type, cc.pii_class, cc.nullable, cc.description
        FROM catalogue_columns cc
        JOIN catalogue_tables ct ON cc.table_id = ct.table_id
        WHERE ct.table_name = ?
        """,
        [table_name],
    ).fetchall()
    con.close()
    return {
        "table": {"name": tbl[1], "schema": tbl[2], "description": tbl[3],
                  "domain": tbl[4], "pii_flag": tbl[5], "tags": tbl[6], "row_count": tbl[7]},
        "columns": [
            {"name": c[0], "type": c[1], "pii_class": c[2], "nullable": c[3], "description": c[4]}
            for c in cols
        ],
    }


@router.get("/catalogue/lineage/{table_name}")
async def table_lineage(table_name: str, depth: int = 2):
    return get_lineage_graph(table_name, depth)


@router.get("/catalogue/pii")
async def pii_tables(domain: str | None = None):
    return search_pii_tables(domain)
