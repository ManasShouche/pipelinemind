# PipelineMind — Developer Guide

How to extend, test, and contribute to PipelineMind.

---

## Development Workflow

### Standard run cycle

```bash
cd /Users/as-mac-1282/Developer/genai_mini/pipelinemind
source .venv/bin/activate
export PYTHONPATH="."

# Terminal 1: API with hot-reload
uvicorn api.main:app --host 0.0.0.0 --port 8000 --reload

# Terminal 2: Streamlit
streamlit run ui/app.py --server.port 8501 --server.address localhost

# Terminal 3: re-index after code changes
python ingestion/ingest_pipeline.py --skip-summaries --force-reindex
```

### Run all tests

```bash
pytest tests/ -v --tb=short
```

### Run with coverage

```bash
pytest tests/ --cov=ingestion --cov=retrieval --cov=agent --cov=api \
    --cov-report=term-missing --cov-report=html:htmlcov
open htmlcov/index.html
```

---

## Adding a New MCP Tool

### Step 1: Write the tool function

Create or add to `agent/tools/<domain>_tools.py`:

```python
def my_new_tool(param_a: str, param_b: int = 10) -> dict:
    """
    Docstring describing what this tool does.
    """
    # Tool logic here
    return {"result": "...", "param_a": param_a}
```

### Step 2: Add a Pydantic validator

In `agent/tools/validators.py`:

```python
class MyNewToolInput(BaseModel):
    param_a: str = Field(..., min_length=1)
    param_b: int = Field(default=10, ge=1, le=100)
```

### Step 3: Register in the agent loop

In `agent/agent_loop.py`, add to `TOOL_REGISTRY`:

```python
from agent.tools.my_tools import my_new_tool
from agent.tools.validators import MyNewToolInput

TOOL_REGISTRY["my_new_tool"] = (MyNewToolInput, my_new_tool)
```

Add to `GROQ_TOOLS`:

```python
{
    "type": "function",
    "function": {
        "name": "my_new_tool",
        "description": "Clear description for the LLM to understand when to use this.",
        "parameters": {
            "type": "object",
            "properties": {
                "param_a": {"type": "string"},
                "param_b": {"type": "integer"},
            },
            "required": ["param_a"],
        },
    },
}
```

### Step 4: Register in the MCP server

In `agent/mcp_server.py`, add to `list_tools()` and `call_tool()`.

### Step 5: Add a REST endpoint (optional)

In `api/routers/` add a new router or extend an existing one.

### Step 6: Write tests

```python
# tests/unit/test_my_tool.py
from agent.tools.validators import MyNewToolInput
from pydantic import ValidationError

def test_valid_input():
    v = MyNewToolInput(param_a="test")
    assert v.param_b == 10

def test_invalid_input():
    with pytest.raises(ValidationError):
        MyNewToolInput(param_a="")
```

---

## Adding a New Chunker

### Step 1: Create the chunk dataclass and chunker class

Follow the pattern in `ingestion/chunkers/ast_chunker.py`:

```python
@dataclass
class MyChunk:
    chunk_id: str
    source_file: str
    chunk_type: str = "my_type"
    chunk_index: int = 0
    language: str = "my_lang"
    raw_code: str = ""
    summary: str = ""
    pipeline_name: str = ""
    pii_flag: bool = False
    tags: list[str] = field(default_factory=list)
    git_commit_hash: str = ""
    content_hash: str = ""
    source_type: str = "my_lang"

class MyChunker:
    def chunk(self, file_path: Path, git_commit_hash: str = "") -> list[MyChunk]:
        ...
```

### Step 2: Register the extension in the ingestion pipeline

In `ingestion/ingest_pipeline.py`:

```python
EXTENSION_MAP[".myext"] = "my_lang"
# ...
self.chunkers["my_lang"] = MyChunker()
```

### Step 3: Add a summary prompt

In `ingestion/summary_generator.py`:

```python
SUMMARY_PROMPTS["my_type"] = "Summarise this ... Under 100 words."
```

---

## Adding a New Intent

### Step 1: Add to the Intent enum

In `retrieval/intent_classifier.py`:

```python
class Intent(str, Enum):
    CODE_QA   = "CODE_QA"
    CATALOGUE = "CATALOGUE"
    HEALTH    = "HEALTH"
    ACTION    = "ACTION"
    GENERAL   = "GENERAL"
    MY_NEW_INTENT = "MY_NEW_INTENT"   # add here
```

### Step 2: Update the classifier system prompt

Add a description of the new intent to `_SYSTEM_PROMPT`.

### Step 3: Handle the intent in `HybridRetriever.retrieve()`

Add a branch for the new intent routing in `retrieval/hybrid_retriever.py`.

---

## Environment Variables Reference

All variables are read via `pm_config.py` (Pydantic-Settings). Changing `.env`
takes effect immediately on the next process start (or hot-reload for the API).

```bash
# Change to use stronger model for summaries
GROQ_MODEL_FAST=llama3-70b-8192

# Disable HyDE for faster (but lower recall) retrieval
HYDE_ENABLED=false

# Tighten confidence threshold (model will express uncertainty more often)
CONFIDENCE_THRESHOLD=0.7

# Increase context window for longer code files
MAX_CONTEXT_TOKENS=8000

# Lower agent guard to prevent long chains in demo
AGENT_MAX_ITERATIONS=3
```

---

## Code Style

- Python 3.11+ type hints everywhere
- `from __future__ import annotations` at the top of every module
- Docstrings on every public class and method
- `logging.getLogger(__name__)` — never `print()` in library code
- No bare `except:` — always catch specific exceptions
- Line length: 100 characters (configured in `pyproject.toml`)

---

## Testing Strategy

| Layer | Location | What is tested |
|---|---|---|
| Unit | `tests/unit/` | Chunkers, RRF fusion, Pydantic validators, ContextBuilder |
| Integration | `tests/integration/` | DuckDB tool functions against seeded database |
| Eval | `tests/eval/` | RAG metrics: MRR@5, NDCG@5, Recall@10, latency |

### Writing a unit test

```python
# tests/unit/test_my_feature.py
from __future__ import annotations
import pytest

def test_basic_case():
    from ingestion.chunkers.sql_chunker import SQLChunker
    import tempfile
    from pathlib import Path

    sql = "SELECT * FROM orders; INSERT INTO foo VALUES (1);"
    tmp = Path(tempfile.mktemp(suffix=".sql"))
    tmp.write_text(sql)
    chunks = SQLChunker().chunk(tmp)
    assert len(chunks) == 2
```

### Writing an integration test

```python
# tests/integration/test_my_tool.py
import pytest

@pytest.fixture(autouse=True)
def _check_db():
    from pm_config import settings
    if not settings.duckdb_path.exists():
        pytest.skip("DuckDB not seeded")

def test_tool_returns_expected_shape():
    from agent.tools.pipeline_tools import get_pipeline_status
    result = get_pipeline_status("orders", lookback_hours=720)
    assert "status" in result
    assert isinstance(result["slo_pct"], float)
```

---

## Useful One-Liners

```bash
# Check what is in ChromaDB
python -c "
import sys; sys.path.insert(0,'.')
import chromadb
from pm_config import settings
c = chromadb.PersistentClient(path=str(settings.chroma_path))
col = c.get_collection('pipelinemind')
print(col.count(), 'documents')
print(col.peek(3))
"

# Query ChromaDB directly
python -c "
import sys; sys.path.insert(0,'.')
import chromadb
from pm_config import settings
from ingestion.embedders import ChunkEmbedder
c = chromadb.PersistentClient(path=str(settings.chroma_path))
col = c.get_collection('pipelinemind')
emb = ChunkEmbedder().embed_query('orders pipeline merge strategy')
results = col.query(query_embeddings=[emb], n_results=3)
for doc in results['documents'][0]:
    print(doc[:200])
    print('---')
"

# Inspect DuckDB tables
python -c "
import sys; sys.path.insert(0,'.')
import duckdb
from pm_config import settings
con = duckdb.connect(str(settings.duckdb_path), read_only=True)
print(con.execute('SELECT * FROM catalogue_tables LIMIT 5').df())
con.close()
"

# Test a tool directly
python -c "
import sys; sys.path.insert(0,'.')
from agent.tools.lineage_tools import analyze_lineage_impact
import json
result = analyze_lineage_impact('dim_users', ['user_id'])
print(json.dumps(result, indent=2))
"

# Test the full retrieval pipeline
python -c "
import sys; sys.path.insert(0,'.')
from retrieval.hybrid_retriever import HybridRetriever
r = HybridRetriever()
result = r.retrieve('Why does the orders pipeline use MERGE strategy?')
print('Intent:', result.intent)
print('Confidence:', result.context.confidence_score)
print('Chunks used:', len(result.context.chunks_used))
print(result.context.context_text[:500])
"

# Re-seed and re-index in one command
python db/seeder.py && python ingestion/ingest_pipeline.py \
    --skip-summaries --force-reindex \
    --repo-path ./data/pipeline_repo \
    --sql-path  ./data/sql \
    --yaml-path ./data/dags \
    --dbt-path  ./data/dbt_project
```
