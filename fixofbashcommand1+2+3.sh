#!/usr/bin/env bash
# ==============================================================================
# PipelineMind — Fix Script
# Resolves: DuckDB executescript, module import path, config name clash
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

GREEN='\033[0;32m'; BLUE='\033[0;34m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[FIX]${NC} $*"; }
step() { echo -e "\n${BLUE}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
die()  { echo -e "${RED}[FATAL]${NC} $*" >&2; exit 1; }

PROJECT_DIR="/Users/as-mac-1282/Developer/genai_mini/pipelinemind"
[[ -d "$PROJECT_DIR" ]] || die "Project dir not found: $PROJECT_DIR"
cd "$PROJECT_DIR"

VENV_PYTHON="$PROJECT_DIR/.venv/bin/python"
[[ -f "$VENV_PYTHON" ]] || die "venv not found — run the Phase 1+2 script first"

# ==============================================================================
# FIX 1 — Rename config.py to pm_config.py to avoid clash with the
#          third-party 'config' package installed in the venv.
#          Then patch every file that imports from 'config'.
# ==============================================================================
step "FIX 1: Rename config.py -> pm_config.py and patch all imports"

# Write the settings module under a collision-safe name
cat << 'PYEOF' > pm_config.py
"""
Shared Pydantic-Settings configuration for PipelineMind.
Named pm_config to avoid collision with the third-party 'config' package
that may be installed in the virtual environment.
"""
from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
        case_sensitive=False,
    )

    # Groq
    groq_api_key: str = Field(..., description="Groq Cloud API key")
    groq_model_fast: str = "llama3-8b-8192"
    groq_model_strong: str = "llama3-70b-8192"
    groq_model_agent: str = "llama-3.3-70b-versatile"

    # Storage paths
    chroma_path: Path = Path("./data/chroma_db")
    duckdb_path: Path = Path("./data/pipelinemind.db")
    pipeline_repo_path: Path = Path("./data/pipeline_repo")
    bm25_index_path: Path = Path("./data/bm25_index.pkl")
    embed_cache_dir: Path = Path("./data/model_cache")

    # Server
    fastapi_host: str = "0.0.0.0"
    fastapi_port: int = 8000
    streamlit_port: int = 8501

    # Logging
    log_level: str = "INFO"
    environment: str = "development"

    # RAG knobs
    max_context_tokens: int = 6000
    top_k_dense: int = 20
    top_k_sparse: int = 20
    top_k_fused: int = 10
    top_k_rerank: int = 5
    rrf_k: int = 60
    confidence_threshold: float = 0.6
    hyde_enabled: bool = True
    rerank_enabled: bool = True

    # Agent
    agent_max_iterations: int = 5


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()


settings: Settings = get_settings()
PYEOF

log "pm_config.py written"

# Patch every Python source file: replace 'from config import' with 'from pm_config import'
# and 'import config' with 'import pm_config'
find "$PROJECT_DIR" -name "*.py" \
    ! -path "*/.venv/*" \
    ! -path "*/data/*" \
    ! -name "pm_config.py" \
    | while read -r f; do
        if grep -q "from config import\|import config" "$f" 2>/dev/null; then
            sed -i '' \
                's/from config import/from pm_config import/g;
                 s/import config$/import pm_config/g' "$f"
            log "  patched: ${f#$PROJECT_DIR/}"
        fi
    done

# Remove the old config.py (it will still shadow via the third-party package,
# but our code no longer imports it)
[[ -f "$PROJECT_DIR/config.py" ]] && rm "$PROJECT_DIR/config.py" && log "Removed old config.py"

# ==============================================================================
# FIX 2 — Add conftest.py at project root so pytest can find all modules.
#          Also update pyproject.toml to set pythonpath = ["."].
# ==============================================================================
step "FIX 2: Add conftest.py for pytest sys.path and update pyproject.toml"

cat << 'PYEOF' > conftest.py
"""
Root conftest.py — inserts the project root at the front of sys.path so that
pytest can resolve 'ingestion', 'retrieval', 'agent', 'api', 'pm_config', etc.
without installing the package in editable mode.
"""
import sys
from pathlib import Path

# Project root must come before venv site-packages to ensure our pm_config.py
# is found instead of any third-party 'config' package.
_project_root = str(Path(__file__).parent.resolve())
if _project_root not in sys.path:
    sys.path.insert(0, _project_root)
PYEOF
log "conftest.py written"

# Patch pyproject.toml: add pythonpath to pytest options
python3 - << 'PYEOF'
from pathlib import Path

toml_path = Path("pyproject.toml")
content = toml_path.read_text()

old = '[tool.pytest.ini_options]\nasyncio_mode = "auto"\ntestpaths = ["tests"]\nlog_cli = true\nlog_level = "INFO"'
new = '[tool.pytest.ini_options]\nasyncio_mode = "auto"\ntestpaths = ["tests"]\nlog_cli = true\nlog_level = "INFO"\npythonpath = ["."]'

if 'pythonpath' not in content:
    content = content.replace(old, new)
    toml_path.write_text(content)
    print("pyproject.toml updated with pythonpath")
else:
    print("pyproject.toml already has pythonpath")
PYEOF

# ==============================================================================
# FIX 3 — Rewrite db/seeder.py using con.execute() per statement
#          (DuckDB has no executescript() method).
# ==============================================================================
step "FIX 3: Rewrite db/seeder.py — replace executescript with per-statement execute"

cat << 'PYEOF' > db/seeder.py
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
PYEOF
log "db/seeder.py rewritten"

# ==============================================================================
# FIX 4 — Patch db/schema.sql: DuckDB uses REFERENCES only if FK enforcement
#          is enabled; also VARCHAR[] syntax needs no quotes for array literals.
#          Replace LAST() aggregate (not in DuckDB 1.x) in routers/pipelines.py.
# ==============================================================================
step "FIX 4: Patch schema.sql and pipelines router for DuckDB compatibility"

cat << 'SQLEOF' > db/schema.sql
-- PipelineMind DuckDB metadata store schema
-- Compatible with DuckDB 1.x (no FK enforcement by default)

CREATE TABLE IF NOT EXISTS catalogue_tables (
    table_id    VARCHAR PRIMARY KEY,
    table_name  VARCHAR NOT NULL,
    schema_name VARCHAR,
    description TEXT,
    domain      VARCHAR,
    pii_flag    BOOLEAN DEFAULT FALSE,
    tags        VARCHAR[],
    row_count   BIGINT  DEFAULT 0,
    created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS catalogue_columns (
    column_id    VARCHAR PRIMARY KEY,
    table_id     VARCHAR NOT NULL,
    column_name  VARCHAR NOT NULL,
    data_type    VARCHAR,
    pii_class    VARCHAR,
    nullable     BOOLEAN DEFAULT TRUE,
    description  TEXT,
    retention_days INTEGER
);

CREATE TABLE IF NOT EXISTS lineage_edges (
    edge_id       VARCHAR PRIMARY KEY,
    source_table  VARCHAR NOT NULL,
    source_column VARCHAR,
    target_table  VARCHAR NOT NULL,
    target_column VARCHAR,
    transformation VARCHAR,
    pipeline_id   VARCHAR,
    created_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS pipeline_runs (
    run_id        VARCHAR PRIMARY KEY,
    pipeline_id   VARCHAR NOT NULL,
    status        VARCHAR NOT NULL,
    start_time    TIMESTAMP,
    duration_secs DOUBLE,
    error_message TEXT,
    slo_met       BOOLEAN DEFAULT TRUE,
    created_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS slo_definitions (
    slo_id      VARCHAR PRIMARY KEY,
    pipeline_id VARCHAR NOT NULL,
    metric_name VARCHAR NOT NULL,
    target_value DOUBLE NOT NULL,
    comparison  VARCHAR NOT NULL,
    window_days INTEGER DEFAULT 7
);

CREATE TABLE IF NOT EXISTS schema_snapshots (
    snapshot_id VARCHAR PRIMARY KEY,
    table_id    VARCHAR,
    table_name  VARCHAR NOT NULL,
    columns_json TEXT NOT NULL,
    captured_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
SQLEOF
log "db/schema.sql rewritten (DuckDB-compatible)"

# Fix LAST() aggregate in pipelines router — not available in DuckDB 1.x
cat << 'PYEOF' > api/routers/pipelines.py
"""
Pipeline status and SLO REST endpoints.
"""
from __future__ import annotations

import logging

import duckdb
from fastapi import APIRouter

from agent.tools.pipeline_tools import get_pipeline_status, get_slo_report
from pm_config import settings

logger = logging.getLogger(__name__)
router = APIRouter()


@router.get("/pipelines")
async def list_pipelines():
    """List all pipelines with their latest run status."""
    con = duckdb.connect(str(settings.duckdb_path), read_only=True)
    # DuckDB 1.x: use a subquery for last_status instead of LAST()
    rows = con.execute(
        """
        WITH ranked AS (
            SELECT
                pipeline_id,
                status,
                start_time,
                ROW_NUMBER() OVER (PARTITION BY pipeline_id ORDER BY start_time DESC) AS rn
            FROM pipeline_runs
        ),
        latest AS (
            SELECT pipeline_id, status AS last_status, start_time AS last_run
            FROM ranked WHERE rn = 1
        ),
        summary AS (
            SELECT
                pipeline_id,
                COUNT(*)                                           AS total_runs,
                SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END) AS success_count
            FROM pipeline_runs
            GROUP BY pipeline_id
        )
        SELECT s.pipeline_id, s.total_runs, s.success_count,
               l.last_run, l.last_status
        FROM summary s
        JOIN latest l USING (pipeline_id)
        ORDER BY s.pipeline_id
        """
    ).fetchall()
    con.close()
    return [
        {
            "pipeline_id":  r[0],
            "total_runs":   r[1],
            "success_rate": round(r[2] / r[1] * 100, 2) if r[1] else 0,
            "last_run":     r[3],
            "last_status":  r[4],
        }
        for r in rows
    ]


@router.get("/pipelines/{pipeline_id}/status")
async def pipeline_status(pipeline_id: str, lookback_hours: int = 24):
    return get_pipeline_status(pipeline_id, lookback_hours)


@router.get("/pipelines/{pipeline_id}/slo")
async def pipeline_slo(pipeline_id: str, window_days: int = 7):
    return get_slo_report(pipeline_id, window_days)
PYEOF
log "api/routers/pipelines.py rewritten (removed LAST() aggregate)"

# ==============================================================================
# FIX 5 — Ensure scripts/ directory exists before writing scripts
# ==============================================================================
step "FIX 5: Recreate scripts directory and startup scripts"

mkdir -p scripts

cat << 'SHEOF' > scripts/start_api.sh
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."
source .venv/bin/activate
echo "[PM] Starting FastAPI on http://localhost:8000"
echo "[PM] API docs: http://localhost:8000/docs"
uvicorn api.main:app --host 0.0.0.0 --port 8000 --reload --log-level info
SHEOF

cat << 'SHEOF' > scripts/start_ui.sh
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."
source .venv/bin/activate
echo "[PM] Starting Streamlit on http://localhost:8501"
streamlit run ui/app.py \
    --server.port 8501 \
    --server.address localhost \
    --server.headless false \
    --browser.gatherUsageStats false
SHEOF

cat << 'SHEOF' > scripts/ingest.sh
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."
source .venv/bin/activate
echo "[PM] Running ingestion pipeline (full LLM summaries)..."
python ingestion/ingest_pipeline.py \
    --repo-path ./data/pipeline_repo \
    --sql-path  ./data/sql \
    --yaml-path ./data/dags \
    --dbt-path  ./data/dbt_project \
    "$@"
SHEOF

cat << 'SHEOF' > scripts/ingest_fast.sh
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."
source .venv/bin/activate
echo "[PM] Running fast ingestion (no LLM summaries)..."
python ingestion/ingest_pipeline.py \
    --repo-path ./data/pipeline_repo \
    --sql-path  ./data/sql \
    --yaml-path ./data/dags \
    --dbt-path  ./data/dbt_project \
    --skip-summaries \
    --force-reindex
SHEOF

cat << 'SHEOF' > scripts/seed_db.sh
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."
source .venv/bin/activate
python db/seeder.py
SHEOF

cat << 'SHEOF' > scripts/run_tests.sh
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."
source .venv/bin/activate
pytest tests/ -v --tb=short
SHEOF

chmod +x scripts/*.sh
log "scripts/ written and made executable"

# ==============================================================================
# FIX 6 — Patch all remaining files that still use 'from config import'
#          (safety pass after the bulk sed above)
# ==============================================================================
step "FIX 6: Final import-patch safety pass"

find "$PROJECT_DIR" -name "*.py" \
    ! -path "*/.venv/*" \
    ! -path "*/data/*" \
    ! -name "pm_config.py" \
    | while read -r f; do
        if grep -q "from config import\|^import config$" "$f" 2>/dev/null; then
            sed -i '' \
                's/from config import/from pm_config import/g;
                 s/^import config$/import pm_config/g' "$f"
            log "  re-patched: ${f#$PROJECT_DIR/}"
        fi
    done

# ==============================================================================
# EXECUTE: Seed DB + Run Tests
# ==============================================================================
step "Seeding DuckDB"

"$VENV_PYTHON" db/seeder.py
log "DuckDB seeded"

step "Verifying DuckDB row counts"

"$VENV_PYTHON" - << 'PYEOF'
import sys
sys.path.insert(0, ".")
import duckdb
from pm_config import settings

con = duckdb.connect(str(settings.duckdb_path), read_only=True)
tables = [
    "catalogue_tables", "catalogue_columns", "lineage_edges",
    "pipeline_runs", "slo_definitions", "schema_snapshots",
]
all_ok = True
for tbl in tables:
    n = con.execute(f"SELECT COUNT(*) FROM {tbl}").fetchone()[0]
    status = "OK" if n > 0 else "EMPTY"
    print(f"  {'[OK]' if n > 0 else '[!!]'} {tbl:<30} {n} rows")
    if n == 0:
        all_ok = False
con.close()
sys.exit(0 if all_ok else 1)
PYEOF

step "Running unit tests"

"$PROJECT_DIR/.venv/bin/pytest" tests/unit/ -v --tb=short

step "Running integration tests"

"$PROJECT_DIR/.venv/bin/pytest" tests/integration/ -v --tb=short

# ==============================================================================
# SUMMARY
# ==============================================================================
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  All fixes applied successfully${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Fixes applied:"
echo "  1. config.py renamed to pm_config.py (avoids venv package clash)"
echo "  2. conftest.py added (pytest sys.path fix)"
echo "  3. db/seeder.py rewritten (executescript -> per-statement execute)"
echo "  4. db/schema.sql rewritten (DuckDB 1.x compatibility)"
echo "  5. api/routers/pipelines.py rewritten (removed LAST() aggregate)"
echo "  6. scripts/ recreated with correct paths"
echo ""
echo "  Next steps:"
echo "  cd $PROJECT_DIR"
echo ""
echo "  Terminal 1 — start backend:"
echo "    bash scripts/start_api.sh"
echo ""
echo "  Terminal 2 — start UI:"
echo "    bash scripts/start_ui.sh"
echo ""
echo "  Run ingestion (fast, no Groq calls):"
echo "    bash scripts/ingest_fast.sh"
echo ""