#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."
source .venv/bin/activate
export PYTHONPATH="."
# Auto-seed DB on first run so tables always exist when the API starts
[[ -f data/pipelinemind.db ]] || python db/seeder.py
echo "[PM] Starting FastAPI on http://localhost:8000"
echo "[PM] API docs: http://localhost:8000/docs"
uvicorn api.main:app --host 0.0.0.0 --port 8000 --reload --log-level info
