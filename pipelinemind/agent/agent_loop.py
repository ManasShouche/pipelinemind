"""
Groq function-calling agent loop.
Implements the plan -> retrieve -> act -> synthesize cycle using
Groq's native function-calling API (parallel to MCP tool dispatch).
Max 5 iterations to prevent runaway loops.
"""
from __future__ import annotations

import json
import logging
import time
from dataclasses import dataclass, field
from typing import Any, Generator

from groq import Groq
from tenacity import retry, stop_after_attempt, wait_exponential, retry_if_exception_type

from pm_config import settings
from agent.tools.dq_tools       import trigger_dq_check
from agent.tools.pipeline_tools  import get_pipeline_status, get_slo_report
from agent.tools.lineage_tools   import get_lineage_graph, analyze_lineage_impact
from agent.tools.catalogue_tools import search_pii_tables
from agent.tools.validators import (
    TriggerDQCheckInput, GetPipelineStatusInput, GetLineageGraphInput,
    AnalyzeLineageImpactInput, SearchPIITablesInput, GetSLOReportInput,
)

logger = logging.getLogger(__name__)

TOOL_REGISTRY: dict[str, tuple[Any, Any]] = {
    "trigger_dq_check":       (TriggerDQCheckInput,       trigger_dq_check),
    "get_pipeline_status":    (GetPipelineStatusInput,     get_pipeline_status),
    "get_lineage_graph":      (GetLineageGraphInput,       get_lineage_graph),
    "analyze_lineage_impact": (AnalyzeLineageImpactInput,  analyze_lineage_impact),
    "search_pii_tables":      (SearchPIITablesInput,       search_pii_tables),
    "get_slo_report":         (GetSLOReportInput,          get_slo_report),
}

GROQ_TOOLS: list[dict] = [
    {
        "type": "function",
        "function": {
            "name": "trigger_dq_check",
            "description": "[REQUIRES_HUMAN_APPROVAL] Run Great Expectations DQ suite on a table.",
            "parameters": {
                "type": "object",
                "properties": {
                    "table_name":   {"type": "string"},
                    "rules_preset": {"type": "string", "enum": ["minimal","standard","strict"]},
                },
                "required": ["table_name"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_pipeline_status",
            "description": "Fetch current run status and history for a pipeline.",
            "parameters": {
                "type": "object",
                "properties": {
                    "pipeline_id":    {"type": "string"},
                    "lookback_hours": {"type": "integer"},
                },
                "required": ["pipeline_id"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_lineage_graph",
            "description": "Get upstream and downstream table lineage.",
            "parameters": {
                "type": "object",
                "properties": {
                    "table_name": {"type": "string"},
                    "depth":      {"type": "integer"},
                },
                "required": ["table_name"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "analyze_lineage_impact",
            "description": "What-If Impact Engine: trace downstream blast radius before dropping columns.",
            "parameters": {
                "type": "object",
                "properties": {
                    "changed_table":   {"type": "string"},
                    "dropped_columns": {"type": "array", "items": {"type": "string"}},
                },
                "required": ["changed_table", "dropped_columns"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "search_pii_tables",
            "description": "List all PII-tagged tables and columns.",
            "parameters": {
                "type": "object",
                "properties": {
                    "domain_filter": {"type": "string"},
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_slo_report",
            "description": "SLO adherence report for a pipeline.",
            "parameters": {
                "type": "object",
                "properties": {
                    "pipeline_id":  {"type": "string"},
                    "window_days":  {"type": "integer"},
                },
                "required": ["pipeline_id"],
            },
        },
    },
]

SYSTEM_PROMPT = """You are PipelineMind, an expert Data Engineering AI assistant.
You have access to tools that query pipeline status, data lineage, PII catalogues,
and can trigger data quality checks (with human approval).

Guidelines:
- Always check pipeline status before recommending actions
- Always run analyze_lineage_impact before any destructive schema change
- For state-altering actions (trigger_dq_check), explicitly state that human approval is required
- Cite sources by referencing retrieved code files and git commit hashes
- If confidence in retrieved information is low, say so explicitly
- Be concise but thorough in your final synthesis
"""


@dataclass
class AgentMessage:
    role: str
    content: str
    tool_calls: list[dict] = field(default_factory=list)
    tool_call_id: str = ""
    name: str = ""


@dataclass
class AgentResult:
    final_response: str
    tool_calls_made: list[dict]
    iterations: int
    requires_approval: bool
    approval_tool: str = ""
    approval_args: dict = field(default_factory=dict)


APPROVAL_REQUIRED_TOOLS = {"trigger_dq_check"}


class AgentLoop:
    """
    Groq function-calling agent with max_iterations guard.
    Detects approval-required tools and pauses for UI confirmation.
    """

    def __init__(self) -> None:
        self._client = Groq(api_key=settings.groq_api_key)

    def run(
        self,
        user_message: str,
        context_text: str = "",
        conversation_history: list[dict] | None = None,
        pending_approval: dict | None = None,
    ) -> AgentResult:
        """
        Run the agent loop.

        Args:
            user_message:          Current user query.
            context_text:          RAG-retrieved context to inject.
            conversation_history:  Prior turns for multi-turn support.
            pending_approval:      If set, execute the previously approved tool call.
        """
        messages: list[dict] = [{"role": "system", "content": SYSTEM_PROMPT}]

        if context_text:
            messages.append({
                "role": "user",
                "content": f"Retrieved context from the knowledge base:\n\n{context_text}",
            })
            messages.append({"role": "assistant", "content": "Understood. I have reviewed the retrieved context."})

        for turn in (conversation_history or []):
            messages.append(turn)

        messages.append({"role": "user", "content": user_message})

        tool_calls_made: list[dict] = []
        requires_approval = False
        approval_tool = ""
        approval_args: dict = {}

        # If a tool was previously approved, execute it first
        if pending_approval:
            tool_result = self._execute_tool(pending_approval["name"], pending_approval["args"])
            messages.append({
                "role": "tool",
                "content": json.dumps(tool_result, default=str),
                "tool_call_id": pending_approval.get("call_id", "approved_call"),
            })
            tool_calls_made.append({"tool": pending_approval["name"], "approved": True})

        for iteration in range(settings.agent_max_iterations):
            try:
                response = self._call_groq(messages)
            except Exception as exc:
                logger.error("Groq call failed at iteration %d: %s", iteration, exc)
                return AgentResult(
                    final_response=f"I encountered an error: {exc}. Please try again.",
                    tool_calls_made=tool_calls_made,
                    iterations=iteration + 1,
                    requires_approval=False,
                )

            choice = response.choices[0]
            msg    = choice.message

            # No tool calls — final text response
            if not msg.tool_calls:
                return AgentResult(
                    final_response=msg.content or "",
                    tool_calls_made=tool_calls_made,
                    iterations=iteration + 1,
                    requires_approval=False,
                )

            # Process tool calls
            messages.append(msg.model_dump(exclude_none=True))

            for tc in msg.tool_calls:
                tool_name = tc.function.name
                try:
                    tool_args = json.loads(tc.function.arguments)
                except json.JSONDecodeError:
                    tool_args = {}

                logger.info("Agent tool call: %s(%s)", tool_name, tool_args)

                # Pause for human approval on state-altering tools
                if tool_name in APPROVAL_REQUIRED_TOOLS:
                    requires_approval = True
                    approval_tool = tool_name
                    approval_args = tool_args
                    return AgentResult(
                        final_response=(
                            f"I need to run `{tool_name}` with parameters: {json.dumps(tool_args)}. "
                            "Please approve or deny this action in the UI."
                        ),
                        tool_calls_made=tool_calls_made,
                        iterations=iteration + 1,
                        requires_approval=True,
                        approval_tool=tool_name,
                        approval_args=tool_args,
                    )

                tool_result = self._execute_tool(tool_name, tool_args)
                tool_calls_made.append({"tool": tool_name, "args": tool_args, "result": tool_result})

                messages.append({
                    "role": "tool",
                    "content": json.dumps(tool_result, default=str),
                    "tool_call_id": tc.id,
                })

        # Force synthesis if max iterations reached
        logger.warning("Agent reached max_iterations=%d — forcing synthesis", settings.agent_max_iterations)
        messages.append({
            "role": "user",
            "content": "Please synthesise your findings into a final answer now.",
        })
        final = self._call_groq(messages, tools=False)
        return AgentResult(
            final_response=final.choices[0].message.content or "Max iterations reached.",
            tool_calls_made=tool_calls_made,
            iterations=settings.agent_max_iterations,
            requires_approval=False,
        )

    @retry(
        stop=stop_after_attempt(3),
        wait=wait_exponential(min=1, max=15),
        reraise=True,
    )
    def _call_groq(self, messages: list[dict], tools: bool = True):
        kwargs: dict = {
            "model":    settings.groq_model_agent,
            "messages": messages,
            "max_tokens": 2048,
            "temperature": 0.2,
        }
        if tools:
            kwargs["tools"]       = GROQ_TOOLS
            kwargs["tool_choice"] = "auto"
        return self._client.chat.completions.create(**kwargs)

    def _execute_tool(self, tool_name: str, tool_args: dict) -> dict:
        if tool_name not in TOOL_REGISTRY:
            return {"error": f"Unknown tool: {tool_name}"}
        model_cls, func = TOOL_REGISTRY[tool_name]
        try:
            validated = model_cls(**tool_args)
            return func(**validated.model_dump())
        except Exception as exc:
            logger.error("Tool %s failed: %s", tool_name, exc)
            return {"error": str(exc)}
