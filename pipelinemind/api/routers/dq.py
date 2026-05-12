"""
DQ check REST endpoints.
"""
from __future__ import annotations

import logging

import duckdb
from fastapi import APIRouter

from agent.tools.dq_tools import trigger_dq_check
from api.models import DQTriggerRequest
from pm_config import settings

logger = logging.getLogger(__name__)
router = APIRouter()


@router.post("/dq/trigger")
async def dq_trigger(request: DQTriggerRequest):
    """Trigger a DQ check (assumes human approval already obtained via UI)."""
    return trigger_dq_check(request.table_name, request.rules_preset)


@router.get("/dq/results/{run_id}")
async def dq_results(run_id: str):
    """Placeholder — real results would be fetched from GE data docs store."""
    return {"run_id": run_id, "status": "completed", "message": "Results available in GE data docs."}
