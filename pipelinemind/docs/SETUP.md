# PipelineMind — Setup Guide

Complete installation and configuration guide for local development and Docker deployment.

---

## Prerequisites

| Requirement | Minimum Version | Check |
|---|---|---|
| Python | 3.11 | `python3 --version` |
| pip | 23+ | `pip --version` |
| Docker Desktop | 24+ | `docker --version` |
| Git | 2.x | `git --version` |
| Groq API Key | — | https://console.groq.com |
| Disk space | 4 GB free | For model cache + ChromaDB |
| RAM | 8 GB recommended | Sentence-transformer models |

---

## Installation — Local Development

### Step 1: Navigate to the project

```bash
cd /Users/as-mac-1282/Developer/genai_mini/pipelinemind
```

### Step 2: Create and activate the virtual environment

```bash
python3.11 -m venv .venv
source .venv/bin/activate
```

### Step 3: Install all dependencies

```bash
pip install --upgrade pip setuptools wheel

# Core runtime
pip install groq tenacity structlog pydantic pydantic-settings python-dotenv pyyaml httpx

# API layer
pip install fastapi "uvicorn[standard]" sse-starlette prometheus-client

# Data layer
pip install duckdb

# Vector search
pip install chromadb rank-bm25

# Embeddings and reranker
pip install "sentence-transformers>=3.0.0"

# Code parsing
pip install tree-sitter tree-sitter-python

# Frontend
pip install streamlit streamlit-agraph

# Utilities
pip install watchdog pandas numpy scikit-learn sqlalchemy

# Testing
pip install pytest pytest-asyncio

# Optional: DQ framework
pip install great-expectations

# Optional: MCP SDK
pip install mcp
```

### Step 4: Configure environment

```bash
cp .env.example .env
```

Edit `.env` and set your Groq API key:

```bash
GROQ_API_KEY=gsk_your_key_here
```

All other defaults work out of the box for local development.

### Step 5: Seed the DuckDB metadata store

```bash
python db/seeder.py
```

Expected output: 6 tables seeded with row counts printed to stdout.

Verify with:

```bash
python -c "
import sys; sys.path.insert(0,'.')
import duckdb
from pm_config import settings
con = duckdb.connect(str(settings.duckdb_path), read_only=True)
for t in ['catalogue_tables','catalogue_columns','lineage_edges',
          'pipeline_runs','slo_definitions','schema_snapshots']:
    print(t, con.execute(f'SELECT COUNT(*) FROM {t}').fetchone()[0])
con.close()
"
```

### Step 6: Run ingestion

**Fast mode** — uses fallback text summaries (no Groq API calls, ~30 seconds):

```bash
export PYTHONPATH="."
python ingestion/ingest_pipeline.py \
    --repo-path ./data/pipeline_repo \
    --sql-path  ./data/sql \
    --yaml-path ./data/dags \
    --dbt-path  ./data/dbt_project \
    --skip-summaries \
    --force-reindex
```

**Full mode** — uses Groq `llama3-8b-8192` for LLM summaries (better retrieval quality):

```bash
export PYTHONPATH="."
python ingestion/ingest_pipeline.py \
    --repo-path ./data/pipeline_repo \
    --sql-path  ./data/sql \
    --yaml-path ./data/dags \
    --dbt-path  ./data/dbt_project
```

Verify ChromaDB was populated:

```bash
python -c "
import sys; sys.path.insert(0,'.')
import chromadb
from pm_config import settings
c = chromadb.PersistentClient(path=str(settings.chroma_path))
col = c.get_or_create_collection('pipelinemind', metadata={'hnsw:space':'cosine'})
print('ChromaDB documents:', col.count())
"
```

### Step 7: Start the API backend

```bash
export PYTHONPATH="."
uvicorn api.main:app --host 0.0.0.0 --port 8000 --reload --log-level info
```

Or use the script:

```bash
bash scripts/start_api.sh
```

Verify the API is up:

```bash
curl http://localhost:8000/api/v1/health
```

Expected: `{"status":"ok","environment":"development",...}`

### Step 8: Start the Streamlit UI (new terminal)

```bash
cd /Users/as-mac-1282/Developer/genai_mini/pipelinemind
source .venv/bin/activate
export PYTHONPATH="."
streamlit run ui/app.py --server.port 8501 --server.address localhost
```

Or:

```bash
bash scripts/start_ui.sh
```

Open http://localhost:8501 in your browser.

---

## Installation — Docker Compose

### Build and start

```bash
cd /Users/as-mac-1282/Developer/genai_mini/pipelinemind

# Ensure .env is configured
cp .env.example .env
# Edit .env and set GROQ_API_KEY

docker compose up --build
```

### Services started

| Service | URL | Container Name |
|---|---|---|
| FastAPI backend | http://localhost:8000 | pipelinemind_api |
| Streamlit UI | http://localhost:8501 | pipelinemind_ui |

### Data persistence

The `./data` directory is mounted into both containers, so ChromaDB, DuckDB, and
BM25 index survive container restarts.

### Seeding inside Docker

```bash
docker compose exec api python db/seeder.py
docker compose exec api python ingestion/ingest_pipeline.py \
    --repo-path ./data/pipeline_repo \
    --sql-path  ./data/sql \
    --yaml-path ./data/dags \
    --dbt-path  ./data/dbt_project \
    --skip-summaries --force-reindex
```

---

## Troubleshooting

### Error: `cannot import name 'settings' from 'config'`

The venv has a third-party `config` package installed. PipelineMind uses `pm_config.py`.
Ensure `PYTHONPATH="."` is exported before running any Python command.

```bash
export PYTHONPATH="."
```

### Error: `DuckDBPyConnection has no attribute executescript`

DuckDB does not support `executescript()`. This was fixed in `db/seeder.py` by
executing statements one at a time. If you see this, re-run:

```bash
python db/seeder.py
```

### Error: `ModuleNotFoundError: No module named 'ingestion'`

`conftest.py` handles this for pytest. For direct Python runs, always set:

```bash
export PYTHONPATH="."
```

### Error: `Table with name catalogue_tables does not exist`

The database was not seeded. Run:

```bash
python db/seeder.py
```

### Error: ChromaDB `0 documents` after ingestion

The ingestion script ran against an empty path. Verify the paths exist:

```bash
ls data/pipeline_repo/   # Should show 5 .py files
ls data/sql/             # Should show 3 .sql files
ls data/dags/            # Should show 3 .yml files
ls data/dbt_project/     # Should show manifest.json
```

Then force re-index:

```bash
python ingestion/ingest_pipeline.py --skip-summaries --force-reindex
```

### Groq rate limit errors during ingestion

Use `--skip-summaries` for local testing. Full LLM summaries are only needed for
production-quality retrieval.

### Port already in use

```bash
# Find what is using port 8000
lsof -i :8000
# Kill it
kill -9 <PID>

# Same for 8501
lsof -i :8501
kill -9 <PID>
```

---

## Model Download (First Run)

On first ingestion, sentence-transformers downloads two models to `./data/model_cache/`:

| Model | Size | Purpose |
|---|---|---|
| `all-mpnet-base-v2` | ~420 MB | General text embedding |
| `microsoft/codebert-base` | ~500 MB | Code-specific embedding |
| `ms-marco-MiniLM-L-6-v2` | ~80 MB | Cross-encoder re-ranking |

Total: ~1 GB download. Subsequent runs load from cache.

To pre-warm the cache:

```bash
python -c "
import sys; sys.path.insert(0,'.')
from ingestion.embedders import _get_text_embedder, _get_code_embedder
from retrieval.reranker import _get_cross_encoder
_get_text_embedder()
_get_code_embedder()
_get_cross_encoder()
print('All models cached.')
"
```
