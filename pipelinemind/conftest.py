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
