"""Pydantic request/response models for the FastAPI layer."""
from __future__ import annotations

from typing import Any, Optional
from pydantic import BaseModel, Field


class ChatRequest(BaseModel):
    message: str = Field(..., min_length=1, max_length=4000)
    conversation_history: list[dict] = Field(default_factory=list)
    pipeline_filter: Optional[str] = None
    intent_override: Optional[str] = None


class ToolApprovalRequest(BaseModel):
    tool_name: str
    tool_args: dict
    call_id: str
    approved: bool


class IngestTriggerRequest(BaseModel):
    repo_path: Optional[str] = None
    force_reindex: bool = False
    skip_summaries: bool = False


class ImpactAnalysisRequest(BaseModel):
    changed_table: str
    dropped_columns: list[str]


class DQTriggerRequest(BaseModel):
    table_name: str
    rules_preset: str = "standard"
