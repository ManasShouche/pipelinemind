"""
What-If Impact Analysis REST endpoint.
"""
from __future__ import annotations

from fastapi import APIRouter

from agent.tools.lineage_tools import analyze_lineage_impact
from api.models import ImpactAnalysisRequest

router = APIRouter()


@router.post("/impact/analyze")
async def impact_analyze(request: ImpactAnalysisRequest):
    return analyze_lineage_impact(request.changed_table, request.dropped_columns)
