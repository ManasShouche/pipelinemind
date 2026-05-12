# Contributing to PipelineMind

---

## Getting Started

1. Fork or clone the repository
2. Follow the setup in `docs/SETUP.md`
3. Create a feature branch: `git checkout -b feature/my-feature`
4. Make changes, add tests, verify all tests pass
5. Submit a pull request

---

## Branch Naming

| Type | Pattern | Example |
|---|---|---|
| Feature | `feature/<name>` | `feature/add-slack-notification-tool` |
| Bug fix | `fix/<name>` | `fix/duckdb-seeder-executescript` |
| Documentation | `docs/<name>` | `docs/api-reference-update` |
| Chore | `chore/<name>` | `chore/upgrade-sentence-transformers` |

---

## Commit Messages

Format: `<type>(<scope>): <description>`

Types: `feat`, `fix`, `docs`, `test`, `refactor`, `chore`

Examples:

```
feat(agent): add Slack notification MCP tool
fix(seeder): replace executescript with per-statement execute for DuckDB 1.x
docs(api): add missing /impact/analyze request body example
test(chunkers): add YAML chunker edge case for missing slo block
refactor(retrieval): extract confidence score calculation into helper method
chore(deps): upgrade sentence-transformers to 3.1.0
```

---

## Pull Request Checklist

- [ ] All existing tests pass: `pytest tests/ -v`
- [ ] New functionality has unit tests in `tests/unit/`
- [ ] New tool integrations have integration tests in `tests/integration/`
- [ ] Type hints on all new functions and methods
- [ ] Docstrings on all new public classes and methods
- [ ] `CHANGELOG.md` entry added under `[Unreleased]`
- [ ] `.env.example` updated if new environment variables were added
- [ ] No secrets committed (API keys, credentials)
- [ ] `export PYTHONPATH="."` works for all new scripts

---

## Code Standards

### Python

```python
# Good — explicit types, docstring, logger, structured return
def get_pipeline_status(pipeline_id: str, lookback_hours: int = 24) -> dict[str, Any]:
    """
    Fetch current run status and history for a pipeline.

    Args:
        pipeline_id: Identifier matching pipeline_runs.pipeline_id in DuckDB.
        lookback_hours: How many hours back to query (1-720).

    Returns:
        Dict with keys: status, last_run, slo_pct, failures, total_runs.
    """
    logger.info("get_pipeline_status | pipeline=%s lookback=%dh", pipeline_id, lookback_hours)
    ...
```

### Tests

```python
# Good — clear test name, single assertion per test, no external dependencies
def test_rrf_document_in_both_lists_ranks_higher():
    dense  = [_make_chunk("shared", 0.9), _make_chunk("dense_only", 0.8)]
    sparse = [_make_chunk("shared", 0.85)]
    result = reciprocal_rank_fusion(dense, sparse, top_n=2)
    assert result[0].chunk_id == "shared"
```

---

## Where to Add New Features

| Feature type | Location |
|---|---|
| New MCP tool | `agent/tools/<domain>_tools.py` + `validators.py` + `agent_loop.py` |
| New chunker | `ingestion/chunkers/<type>_chunker.py` + `ingest_pipeline.py` |
| New API endpoint | `api/routers/<domain>.py` + `api/models/__init__.py` |
| New UI page | `ui/pages/<N>_<Name>.py` + `ui/components/<component>.py` |
| New intent | `retrieval/intent_classifier.py` + `hybrid_retriever.py` |
| New DuckDB table | `db/schema.sql` + `db/seeder.py` + fixture JSON |

---

## Reporting Issues

When reporting a bug, include:

1. Python version (`python3 --version`)
2. The exact error message and traceback
3. The command that triggered the error
4. Output of `python -c "from pm_config import settings; print(settings.duckdb_path)"`
5. ChromaDB document count: `python -c "import sys,chromadb; sys.path.insert(0,'.'); from pm_config import settings; c=chromadb.PersistentClient(str(settings.chroma_path)); print(c.get_or_create_collection('pipelinemind').count())"`
