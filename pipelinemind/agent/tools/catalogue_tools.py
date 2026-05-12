"""
search_pii_tables MCP tool.
Queries the DuckDB catalogue for PII-tagged tables and columns.
"""
from __future__ import annotations

import logging
from typing import Any, Optional

import duckdb

from pm_config import settings

logger = logging.getLogger(__name__)


def search_pii_tables(domain_filter: Optional[str] = None) -> list[dict[str, Any]]:
    """
    Return all PII-tagged tables and their sensitive columns.

    Args:
        domain_filter: Optional domain name to narrow results (e.g. "users", "finance").

    Returns:
        List of {table, domain, columns: [{column_name, pii_class, sensitivity_level}]}
    """
    logger.info("search_pii_tables | domain_filter=%s", domain_filter)
    con = duckdb.connect(str(settings.duckdb_path), read_only=True)

    params: list[Any] = []
    domain_clause = ""
    if domain_filter:
        domain_clause = "AND ct.domain = ?"
        params.append(domain_filter)

    rows = con.execute(
        f"""
        SELECT
            ct.table_name,
            ct.domain,
            cc.column_name,
            cc.pii_class,
            cc.retention_days
        FROM catalogue_columns cc
        JOIN catalogue_tables ct ON cc.table_id = ct.table_id
        WHERE cc.pii_class IS NOT NULL
          {domain_clause}
        ORDER BY ct.table_name, cc.pii_class
        """,
        params,
    ).fetchall()
    con.close()

    grouped: dict[str, dict] = {}
    for table_name, domain, col_name, pii_class, retention in rows:
        if table_name not in grouped:
            grouped[table_name] = {
                "table": table_name,
                "domain": domain,
                "sensitivity_level": "high" if "HIGH" in (pii_class or "") else "medium",
                "columns": [],
            }
        grouped[table_name]["columns"].append({
            "column_name": col_name,
            "pii_class": pii_class,
            "retention_days": retention,
        })

    return list(grouped.values())
