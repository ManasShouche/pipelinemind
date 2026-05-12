"""
Pydantic v2 models for all MCP tool input parameters.
Invalid inputs are caught here before execution and returned to the LLM
as structured error strings, enabling self-correction without crashing.
"""
from __future__ import annotations

from typing import Optional
from pydantic import BaseModel, Field, field_validator


class TriggerDQCheckInput(BaseModel):
    table_name: str = Field(..., min_length=1, description="Target table name")
    rules_preset: str = Field(
        default="standard",
        description="GE expectations preset: standard | strict | minimal",
    )

    @field_validator("rules_preset")
    @classmethod
    def valid_preset(cls, v: str) -> str:
        allowed = {"standard", "strict", "minimal"}
        if v not in allowed:
            raise ValueError(f"rules_preset must be one of {allowed}, got '{v}'")
        return v


class GetPipelineStatusInput(BaseModel):
    pipeline_id: str = Field(..., min_length=1)
    lookback_hours: int = Field(default=24, ge=1, le=720)


class GetLineageGraphInput(BaseModel):
    table_name: str = Field(..., min_length=1)
    depth: int = Field(default=2, ge=1, le=5)


class AnalyzeLineageImpactInput(BaseModel):
    changed_table: str = Field(..., min_length=1)
    dropped_columns: list[str] = Field(..., min_length=1)

    @field_validator("dropped_columns")
    @classmethod
    def non_empty_columns(cls, v: list[str]) -> list[str]:
        if not v or any(not c.strip() for c in v):
            raise ValueError("dropped_columns must be a non-empty list of non-blank strings")
        return [c.strip() for c in v]


class SearchPIITablesInput(BaseModel):
    domain_filter: Optional[str] = Field(
        default=None,
        description="Optional domain to filter (finance, users, product, operations)",
    )


class GetSLOReportInput(BaseModel):
    pipeline_id: str = Field(..., min_length=1)
    window_days: int = Field(default=7, ge=1, le=90)
