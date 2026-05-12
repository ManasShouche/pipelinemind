"""
DuckDB metadata store seeder.
Reads synthetic JSON fixtures and populates all 6 metadata tables.
Safe to re-run (INSERT OR REPLACE).

DuckDB does not have executescript(); statements are executed one at a time.
"""
from __future__ import annotations

import hashlib
import json
import logging
import sys
from pathlib import Path

import duckdb

sys.path.insert(0, str(Path(__file__).parent.parent))
from pm_config import settings

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger(__name__)

FIXTURES = Path(__file__).parent.parent / "data"


def _uid(*parts: str) -> str:
    return hashlib.sha256("|".join(parts).encode()).hexdigest()[:16]


def _execute_schema(con: duckdb.DuckDBPyConnection, schema_path: Path) -> None:
    """Execute a SQL file statement-by-statement (DuckDB has no executescript)."""
    sql = schema_path.read_text()
    # Strip block comments
    import re
    sql = re.sub(r"/\*.*?\*/", " ", sql, flags=re.DOTALL)
    statements = []
    current: list[str] = []
    for line in sql.splitlines():
        stripped = line.strip()
        if stripped.startswith("--"):
            continue
        if ";" in line:
            before, _, _ = line.partition(";")
            current.append(before)
            stmt = "\n".join(current).strip()
            if stmt:
                statements.append(stmt)
            current = []
        else:
            current.append(line)
    if current:
        stmt = "\n".join(current).strip()
        if stmt:
            statements.append(stmt)

    for stmt in statements:
        if stmt.strip():
            try:
                con.execute(stmt)
            except Exception as exc:
                logger.warning("Schema statement skipped (%s): %.80s", exc, stmt)


def seed_tables(con: duckdb.DuckDBPyConnection) -> int:
    rows = json.loads((FIXTURES / "catalogue" / "tables_metadata.json").read_text())
    count = 0
    for r in rows:
        con.execute("DELETE FROM catalogue_tables WHERE table_id = ?", [r["table_id"]])
        con.execute(
            """
            INSERT INTO catalogue_tables
                (table_id, table_name, schema_name, description, domain, pii_flag, tags, row_count)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [r["table_id"], r["table_name"], r.get("schema"), r.get("description"),
             r.get("domain"), bool(r.get("pii_flag", False)),
             r.get("tags", []), r.get("row_count", 0)],
        )
        count += 1
    logger.info("Seeded %d catalogue tables", count)
    return count


def seed_columns(con: duckdb.DuckDBPyConnection) -> int:
    pii_rows = json.loads((FIXTURES / "catalogue" / "pii_registry.json").read_text())
    tables = {
        r["table_name"]: r["table_id"]
        for r in json.loads((FIXTURES / "catalogue" / "tables_metadata.json").read_text())
    }
    count = 0
    for r in pii_rows:
        table_id = tables.get(r["table_name"])
        if not table_id:
            continue
        col_id = _uid(r["table_name"], r["column_name"])
        con.execute("DELETE FROM catalogue_columns WHERE column_id = ?", [col_id])
        con.execute(
            """
            INSERT INTO catalogue_columns
                (column_id, table_id, column_name, data_type, pii_class, retention_days)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [col_id, table_id, r["column_name"],
             r.get("data_type"), r.get("pii_class"), r.get("retention_days")],
        )
        count += 1
    logger.info("Seeded %d PII columns", count)
    return count


def seed_lineage(con: duckdb.DuckDBPyConnection) -> int:
    rows = json.loads((FIXTURES / "catalogue" / "lineage_edges.json").read_text())
    count = 0
    for r in rows:
        edge_id = _uid(
            r["source_table"], r.get("source_column", ""),
            r["target_table"], r.get("target_column", ""),
        )
        con.execute("DELETE FROM lineage_edges WHERE edge_id = ?", [edge_id])
        con.execute(
            """
            INSERT INTO lineage_edges
                (edge_id, source_table, source_column, target_table,
                 target_column, transformation, pipeline_id)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [edge_id, r["source_table"], r.get("source_column"),
             r["target_table"], r.get("target_column"),
             r.get("transformation"), r.get("pipeline_id")],
        )
        count += 1
    logger.info("Seeded %d lineage edges", count)
    return count


def seed_pipeline_runs(con: duckdb.DuckDBPyConnection) -> int:
    from datetime import datetime, timedelta

    rows = json.loads((FIXTURES / "run_logs" / "pipeline_runs.json").read_text())

    # Shift timestamps so the most-recent run lands at "now".
    # Keeps relative spacing intact so rolling-window queries always find data.
    timestamps = [
        datetime.fromisoformat(r["start_time"])
        for r in rows if r.get("start_time")
    ]
    if timestamps:
        offset = datetime.utcnow() - max(timestamps)
    else:
        offset = timedelta(0)

    def _shift(ts_str):
        if not ts_str:
            return None
        return (datetime.fromisoformat(ts_str) + offset).isoformat(timespec="seconds")

    count = 0
    for r in rows:
        con.execute("DELETE FROM pipeline_runs WHERE run_id = ?", [r["run_id"]])
        con.execute(
            """
            INSERT INTO pipeline_runs
                (run_id, pipeline_id, status, start_time,
                 duration_secs, error_message, slo_met)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [r["run_id"], r["pipeline_id"], r["status"],
             _shift(r.get("start_time")), r.get("duration_secs"),
             r.get("error_message"), bool(r.get("slo_met", True))],
        )
        count += 1
    logger.info("Seeded %d pipeline runs", count)
    return count


def seed_slo_definitions(con: duckdb.DuckDBPyConnection) -> int:
    definitions = [
        ("slo_orders",    "orders",    "success_rate_pct", 99.5, "gte", 7),
        ("slo_users",     "users",     "success_rate_pct", 99.0, "gte", 7),
        ("slo_inventory", "inventory", "success_rate_pct", 98.0, "gte", 7),
        ("slo_sessions",  "sessions",  "success_rate_pct", 99.0, "gte", 7),
        ("slo_metrics",   "metrics",   "success_rate_pct", 99.0, "gte", 7),
    ]
    for row in definitions:
        con.execute("DELETE FROM slo_definitions WHERE slo_id = ?", [row[0]])
        con.execute(
            """
            INSERT INTO slo_definitions
                (slo_id, pipeline_id, metric_name, target_value, comparison, window_days)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            list(row),
        )
    logger.info("Seeded %d SLO definitions", len(definitions))
    return len(definitions)


def seed_schema_snapshots(con: duckdb.DuckDBPyConnection) -> int:
    snapshot = json.loads(
        (FIXTURES / "schema_snapshots" / "baseline.json").read_text()
    )
    tables = {
        r["table_name"]: r["table_id"]
        for r in json.loads((FIXTURES / "catalogue" / "tables_metadata.json").read_text())
    }
    count = 0
    for table_name, table_data in snapshot["tables"].items():
        table_id = tables.get(table_name)
        snap_id  = _uid(snapshot["snapshot_id"], table_name)
        con.execute("DELETE FROM schema_snapshots WHERE snapshot_id = ?", [snap_id])
        con.execute(
            """
            INSERT INTO schema_snapshots
                (snapshot_id, table_id, table_name, columns_json, captured_at)
            VALUES (?, ?, ?, ?, ?)
            """,
            [snap_id, table_id, table_name,
             json.dumps(table_data["columns"]), snapshot["captured_at"]],
        )
        count += 1
    logger.info("Seeded %d schema snapshots", count)
    return count


def main() -> None:
    db_path = settings.duckdb_path
    db_path.parent.mkdir(parents=True, exist_ok=True)

    # Remove stale DB so schema is applied cleanly
    if db_path.exists():
        db_path.unlink()
        logger.info("Removed stale database: %s", db_path)

    logger.info("Connecting to DuckDB at %s", db_path)
    con = duckdb.connect(str(db_path))

    schema_path = Path(__file__).parent / "schema.sql"
    logger.info("Applying schema from %s", schema_path)
    _execute_schema(con, schema_path)
    logger.info("Schema applied")

    seed_tables(con)
    seed_columns(con)
    seed_lineage(con)
    seed_pipeline_runs(con)
    seed_slo_definitions(con)
    seed_schema_snapshots(con)

    for tbl in [
        "catalogue_tables", "catalogue_columns", "lineage_edges",
        "pipeline_runs", "slo_definitions", "schema_snapshots",
    ]:
        n = con.execute(f"SELECT COUNT(*) FROM {tbl}").fetchone()[0]
        logger.info("  %-30s  %d rows", tbl, n)

    con.close()
    logger.info("DuckDB seeding complete: %s", db_path)


if __name__ == "__main__":
    main()
