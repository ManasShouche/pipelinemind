# PipelineMind — Bash Commands Reference

All commands assume you are in the project root:
```bash
cd /Users/as-mac-1282/Developer/genai_mini/pipelinemind
```

---

## Environment Setup

```bash
# Activate virtual environment
source .venv/bin/activate

# Always set PYTHONPATH before any Python command
export PYTHONPATH="."

# Verify environment
python -c "from pm_config import settings; print(settings.groq_model_agent)"
```

---

## Database

```bash
# Seed DuckDB (creates/resets all 6 tables)
python db/seeder.py

# Verify seeding
python -c "
import sys; sys.path.insert(0,'.')
import duckdb
from pm_config import settings
con = duckdb.connect(str(settings.duckdb_path), read_only=True)
for t in ['catalogue_tables','catalogue_columns','lineage_edges',
          'pipeline_runs','slo_definitions','schema_snapshots']:
    n = con.execute(f'SELECT COUNT(*) FROM {t}').fetchone()[0]
    print(f'{t:<30} {n} rows')
con.close()
"

# Using the script
bash scripts/seed_db.sh
```

---

## Ingestion

```bash
# Fast ingestion — no Groq API calls, fallback summaries (~30 seconds)
export PYTHONPATH="."
python ingestion/ingest_pipeline.py \
    --repo-path ./data/pipeline_repo \
    --sql-path  ./data/sql \
    --yaml-path ./data/dags \
    --dbt-path  ./data/dbt_project \
    --skip-summaries \
    --force-reindex

# Full LLM ingestion — Groq summaries, better retrieval quality
python ingestion/ingest_pipeline.py \
    --repo-path ./data/pipeline_repo \
    --sql-path  ./data/sql \
    --yaml-path ./data/dags \
    --dbt-path  ./data/dbt_project

# Using scripts
bash scripts/ingest_fast.sh
bash scripts/ingest.sh

# Verify ChromaDB population
python -c "
import sys; sys.path.insert(0,'.')
import chromadb
from pm_config import settings
c = chromadb.PersistentClient(path=str(settings.chroma_path))
col = c.get_or_create_collection('pipelinemind', metadata={'hnsw:space':'cosine'})
print('ChromaDB documents:', col.count())
"

# Wipe and re-index (clears ChromaDB and BM25 state)
rm -rf data/chroma_db data/bm25_index.pkl data/.file_hashes.json
python db/seeder.py
bash scripts/ingest_fast.sh
```

---

## API Backend

```bash
# Start with hot-reload (development)
export PYTHONPATH="."
uvicorn api.main:app --host 0.0.0.0 --port 8000 --reload --log-level info

# Start without reload (production-like)
uvicorn api.main:app --host 0.0.0.0 --port 8000 --workers 1

# Using script
bash scripts/start_api.sh

# Health check
curl http://localhost:8000/api/v1/health

# Test chat endpoint (non-streaming)
curl -X POST http://localhost:8000/api/v1/chat \
    -H "Content-Type: application/json" \
    -d '{"message": "What pipelines are available?", "conversation_history": []}' \
    --no-buffer

# List all pipelines
curl http://localhost:8000/api/v1/pipelines | python -m json.tool

# Pipeline status
curl "http://localhost:8000/api/v1/pipelines/orders/status?lookback_hours=72" | python -m json.tool

# SLO report
curl "http://localhost:8000/api/v1/pipelines/orders/slo?window_days=30" | python -m json.tool

# List catalogue tables
curl http://localhost:8000/api/v1/catalogue/tables | python -m json.tool

# Table detail
curl http://localhost:8000/api/v1/catalogue/tables/dim_users | python -m json.tool

# Lineage graph
curl "http://localhost:8000/api/v1/catalogue/lineage/orders_fact?depth=2" | python -m json.tool

# PII tables
curl http://localhost:8000/api/v1/catalogue/pii | python -m json.tool

# What-If impact analysis
curl -X POST http://localhost:8000/api/v1/impact/analyze \
    -H "Content-Type: application/json" \
    -d '{"changed_table": "stg_users", "dropped_columns": ["user_id", "email"]}' \
    | python -m json.tool

# Schema drift check
curl http://localhost:8000/api/v1/schema-drift | python -m json.tool

# Prometheus metrics
curl http://localhost:8000/metrics

# OpenAPI JSON spec
curl http://localhost:8000/openapi.json | python -m json.tool
```

---

## Streamlit UI

```bash
# Start UI
export PYTHONPATH="."
streamlit run ui/app.py \
    --server.port 8501 \
    --server.address localhost \
    --server.headless false \
    --browser.gatherUsageStats false

# Using script
bash scripts/start_ui.sh

# Start headless (for server deployment)
streamlit run ui/app.py \
    --server.port 8501 \
    --server.address 0.0.0.0 \
    --server.headless true
```

---

## Testing

```bash
# All tests
export PYTHONPATH="."
pytest tests/ -v --tb=short

# Unit tests only
pytest tests/unit/ -v --tb=short

# Integration tests only (requires seeded DB)
pytest tests/integration/ -v --tb=short

# Specific test file
pytest tests/unit/test_chunkers.py -v

# Specific test
pytest tests/unit/test_rrf_fusion.py::test_rrf_combines_both_lists -v

# With coverage
pytest tests/ --cov=ingestion --cov=retrieval --cov=agent --cov=api \
    --cov-report=term-missing --cov-report=html:htmlcov

# Using script
bash scripts/run_tests.sh
```

---

## Docker

```bash
# Build and start all services
docker compose up --build

# Start in background
docker compose up -d

# View logs (API)
docker compose logs -f api

# View logs (UI)
docker compose logs -f ui

# Seed and ingest inside container
docker compose exec api python db/seeder.py
docker compose exec api bash -c "export PYTHONPATH=. && python ingestion/ingest_pipeline.py \
    --repo-path ./data/pipeline_repo \
    --sql-path  ./data/sql \
    --yaml-path ./data/dags \
    --dbt-path  ./data/dbt_project \
    --skip-summaries --force-reindex"

# Rebuild single service
docker compose build api
docker compose up -d api

# Stop all
docker compose down

# Stop and remove volumes
docker compose down -v

# Check running containers
docker compose ps
```

---

## Debugging

```bash
# Test a single MCP tool directly
export PYTHONPATH="."
python -c "
from agent.tools.pipeline_tools import get_pipeline_status
import json; print(json.dumps(get_pipeline_status('orders', 168), indent=2, default=str))
"

python -c "
from agent.tools.lineage_tools import analyze_lineage_impact
import json; print(json.dumps(analyze_lineage_impact('dim_users', ['user_id']), indent=2))
"

python -c "
from agent.tools.catalogue_tools import search_pii_tables
import json; print(json.dumps(search_pii_tables(), indent=2))
"

# Test intent classifier
python -c "
import sys; sys.path.insert(0,'.')
from retrieval.intent_classifier import IntentClassifier
clf = IntentClassifier()
for q in [
    'Why does the orders pipeline use MERGE?',
    'What PII columns exist in dim_users?',
    'Did the orders pipeline fail today?',
    'What happens if I drop user_id from stg_users?',
    'What is incremental loading?',
]:
    intent, conf = clf.classify(q)
    print(f'{intent.value:<12} ({conf:.2f})  {q[:60]}')
"

# Test HyDE
python -c "
import sys; sys.path.insert(0,'.')
from retrieval.hyde import HyDEProcessor
hypo = HyDEProcessor().generate('Why does the orders pipeline use MERGE?')
print(hypo)
"

# Test full retrieval pipeline
python -c "
import sys; sys.path.insert(0,'.')
from retrieval.hybrid_retriever import HybridRetriever
r = HybridRetriever()
result = r.retrieve('Why does the orders pipeline use MERGE strategy?')
print('Intent:    ', result.intent)
print('HyDE query:', result.hyde_query[:100])
print('Confidence:', result.context.confidence_score)
print('Chunks:    ', len(result.context.chunks_used))
print('Has PII:   ', result.context.has_pii)
print()
print(result.context.context_text[:600])
"

# Check port usage
lsof -i :8000
lsof -i :8501

# Kill process on port
lsof -ti :8000 | xargs kill -9

# Watch API logs in real time
tail -f logs/*.log 2>/dev/null || echo "No log files yet"
```

---

## Maintenance

```bash
# Update all pip packages
source .venv/bin/activate
pip list --outdated
pip install --upgrade groq chromadb sentence-transformers

# Clear model cache (forces re-download)
rm -rf data/model_cache/

# Clear ChromaDB (forces full re-index)
rm -rf data/chroma_db/ data/bm25_index.pkl data/.file_hashes.json

# Clear DuckDB (forces re-seed)
rm -f data/pipelinemind.db

# Full reset (wipe everything, start fresh)
rm -rf data/chroma_db/ data/bm25_index.pkl data/.file_hashes.json data/pipelinemind.db
python db/seeder.py
bash scripts/ingest_fast.sh

# Check disk usage
du -sh data/chroma_db/ data/pipelinemind.db data/model_cache/ data/bm25_index.pkl 2>/dev/null
```
