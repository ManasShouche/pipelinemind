#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."
source .venv/bin/activate
export PYTHONPATH="."
# Seed DB if not already present
[[ -f data/pipelinemind.db ]] || python db/seeder.py
echo "[PM] Running ingestion pipeline (full LLM summaries)..."
python ingestion/ingest_pipeline.py \
    --repo-path ./data/pipeline_repo \
    --sql-path  ./data/sql \
    --yaml-path ./data/dags \
    --dbt-path  ./data/dbt_project \
    "$@"
