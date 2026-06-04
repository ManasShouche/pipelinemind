"""
Groq function-calling agent loop.

Key behavioral changes from v0.1:
  1. System prompt no longer has "always check X" proactive rules.
     The agent is now instructed to answer exactly what was asked and stop.
  2. Tool availability is filtered by intent — the agent cannot call
     pipeline-status tools for a catalogue/lineage query.
  3. Per-intent tool-call budget enforced independently of max_iterations.
  4. All LLM calls go through LLMRouter (CallType.AGENT = llama-3.3-70b).
"""
from __future__ import annotations

import json
import logging
import time
from dataclasses import dataclass, field
from typing import Any, Callable

from groq import RateLimitError
from tenacity import retry, stop_after_attempt, wait_exponential, retry_if_exception_type

from agent.llm_router import CallType, router
from agent.tools.dq_tools       import trigger_dq_check
from agent.tools.pipeline_tools  import get_pipeline_status, get_slo_report
from agent.tools.lineage_tools   import get_lineage_graph, analyze_lineage_impact
from agent.tools.catalogue_tools import search_pii_tables
from agent.tools.validators import (
    TriggerDQCheckInput, GetPipelineStatusInput, GetLineageGraphInput,
    AnalyzeLineageImpactInput, SearchPIITablesInput, GetSLOReportInput,
)
from pm_config import settings

logger = logging.getLogger(__name__)

# ── Tool registry ─────────────────────────────────────────────────────────────
TOOL_REGISTRY: dict[str, tuple[Any, Any]] = {
    "trigger_dq_check":       (TriggerDQCheckInput,       trigger_dq_check),
    "get_pipeline_status":    (GetPipelineStatusInput,     get_pipeline_status),
    "get_lineage_graph":      (GetLineageGraphInput,       get_lineage_graph),
    "analyze_lineage_impact": (AnalyzeLineageImpactInput,  analyze_lineage_impact),
    "search_pii_tables":      (SearchPIITablesInput,       search_pii_tables),
    "get_slo_report":         (GetSLOReportInput,          get_slo_report),
}

# ── Full Groq tool definitions ────────────────────────────────────────────────
_ALL_TOOL_DEFS: dict[str, dict] = {
    "trigger_dq_check": {
        "type": "function",
        "function": {
            "name": "trigger_dq_check",
            "description": "[REQUIRES_HUMAN_APPROVAL] Run a Great Expectations DQ suite on a table.",
            "parameters": {
                "type": "object",
                "properties": {
                    "table_name":   {"type": "string"},
                    "rules_preset": {"type": "string", "enum": ["minimal", "standard", "strict"]},
                },
                "required": ["table_name"],
            },
        },
    },
    "get_pipeline_status": {
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
    "get_lineage_graph": {
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
    "analyze_lineage_impact": {
        "type": "function",
        "function": {
            "name": "analyze_lineage_impact",
            "description": (
                "What-If Impact Engine: ONLY use this when the user explicitly asks "
                "what will break or be affected if a column is dropped or renamed. "
                "Do NOT call this speculatively after get_lineage_graph."
            ),
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
    "search_pii_tables": {
        "type": "function",
        "function": {
            "name": "search_pii_tables",
            "description": "List all PII-tagged tables and their sensitive columns.",
            "parameters": {
                "type": "object",
                "properties": {
                    "domain_filter": {"type": "string"},
                },
            },
        },
    },
    "get_slo_report": {
        "type": "function",
        "function": {
            "name": "get_slo_report",
            "description": "SLO adherence report for a pipeline over a rolling time window.",
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
}

# ── Intent-to-tool mapping (THE CORE OVER-AGENTIC FIX) ───────────────────────
#
# By restricting which tools are visible to the model per intent, the agent
# cannot make off-topic tool calls even if the system prompt were less precise.
# Defense-in-depth: prompt fix + structural tool restriction.
#
# CODE_QA  → no tools (pure RAG answer, code context injected separately)
# CATALOGUE → only lineage + PII search (NO pipeline status, NO SLO, NO DQ)
# HEALTH   → only status + SLO (NO lineage, NO DQ trigger)
# ACTION   → all tools (user explicitly requested an action)
# GENERAL  → no tools (direct LLM answer, no retrieval needed)
# None     → all tools (unknown intent, allow full capability)

INTENT_TOOL_ALLOWLIST: dict[str | None, list[str]] = {
    "CODE_QA":   [],   # pure RAG — no tool calls at all
    "CATALOGUE": ["get_lineage_graph", "search_pii_tables"],
    "HEALTH":    ["get_pipeline_status", "get_slo_report"],
    "ACTION":    list(_ALL_TOOL_DEFS.keys()),  # all 6
    "GENERAL":   [],   # direct answer — no tools
    None:        list(_ALL_TOOL_DEFS.keys()),  # fallback: full capability
}

# Per-intent maximum tool call iterations
INTENT_MAX_ITERATIONS: dict[str | None, int] = {
    "CODE_QA":   0,   # never enters tool loop
    "CATALOGUE": 1,   # one lineage/PII call then synthesise
    "HEALTH":    2,   # status + SLO, then synthesise
    "ACTION":    5,   # full agent budget for complex action sequences
    "GENERAL":   0,   # never enters tool loop
    None:        3,   # conservative fallback
}

APPROVAL_REQUIRED_TOOLS = {"trigger_dq_check"}

# ── System prompt (REWRITTEN — no more "always check X" rules) ───────────────
_SYSTEM_PROMPT = """You are PipelineMind, an expert Data Engineering AI assistant.

CORE RULE — ANSWER SCOPE:
Answer EXACTLY what the user asked. Do not go beyond the scope of the question.
Do not call tools speculatively "to provide more context" or "to be thorough".
Call a tool ONLY if its output is directly necessary to answer the specific question.

TOOL USAGE RULES:
- get_lineage_graph: call ONLY if the user asks about lineage, dependencies, or which tables are connected.
- analyze_lineage_impact: call ONLY if the user explicitly asks what will break or be affected by a schema change (dropping/renaming columns). Do NOT call this after get_lineage_graph automatically.
- get_pipeline_status: call ONLY if the user asks about run status, failures, or recent runs.
- get_slo_report: call ONLY if the user asks about SLO adherence, SLO breaches, or compliance.
- search_pii_tables: call ONLY if the user asks about PII columns or sensitive data.
- trigger_dq_check: call ONLY if the user explicitly asks to run a data quality check. Always requires human approval — state this before proceeding.

STOP AFTER ANSWERING:
Once you have the information needed to answer the question, synthesise and respond.
Do not chain additional tool calls unless the user's question requires them.

CONFIDENCE:
If retrieved context has low confidence scores, say so explicitly.
Do not fabricate information about tables or pipelines not in the retrieved context.

PII:
When referencing PII-tagged columns, add a clear warning in your response.

CITATIONS:
When using retrieved code, cite the source file and git commit hash if available.
"""


@dataclass
class AgentResult:
    final_response:   str
    tool_calls_made:  list[dict]
    iterations:       int
    requires_approval: bool
    approval_tool:    str = ""
    approval_args:    dict = field(default_factory=dict)


def _get_tools_for_intent(intent: str | None) -> list[dict]:
    """Return the Groq tool definitions allowed for the given intent."""
    allowed_names = INTENT_TOOL_ALLOWLIST.get(intent, list(_ALL_TOOL_DEFS.keys()))
    return [_ALL_TOOL_DEFS[name] for name in allowed_names if name in _ALL_TOOL_DEFS]


def _get_max_iterations(intent: str | None) -> int:
    return INTENT_MAX_ITERATIONS.get(intent, 3)


class AgentLoop:
    """
    Groq function-calling agent with:
    - Intent-aware tool filtering (prevents off-topic tool calls)
    - Per-intent iteration budget (CATALOGUE max 1, HEALTH max 2, ACTION max 5)
    - Focused system prompt (no proactive "always check" rules)
    - All calls routed through LLMRouter (CallType.AGENT)
    """

    def run(
        self,
        user_message: str,
        context_text: str = "",
        conversation_history: list[dict] | None = None,
        pending_approval: dict | None = None,
        intent: str | None = None,
        trace_callback: Callable[[dict], None] | None = None,
    ) -> AgentResult:
        """
        Run the agent loop.

        Args:
            user_message:          Current user query.
            context_text:          RAG-retrieved context to inject.
            conversation_history:  Prior turns for multi-turn support.
            pending_approval:      Execute a previously approved tool call.
            intent:                Detected intent string — used to filter tools
                                   and cap iterations.
            trace_callback:        Optional sink for live agent-decision events.
                                   Called with {"phase": ..., ...} dicts so the
                                   API layer can stream them to the UI.
        """
        def _trace(phase: str, **payload: Any) -> None:
            if trace_callback is None:
                return
            try:
                trace_callback({"phase": phase, **payload})
            except Exception as exc:
                logger.debug("trace_callback failed for phase=%s: %s", phase, exc)
        messages: list[dict] = [{"role": "system", "content": _SYSTEM_PROMPT}]

        if context_text.strip():
            messages.append({
                "role": "user",
                "content": (
                    "Retrieved context from the knowledge base (use only if relevant "
                    "to the user's specific question):\n\n" + context_text
                ),
            })
            messages.append({
                "role": "assistant",
                "content": "Understood. I will use only the relevant parts of this context.",
            })

        for turn in (conversation_history or []):
            messages.append(turn)

        # Scope constraint injected per-message so the model sees it immediately
        # before deciding whether to call a tool.
        scoped_message = (
            f"{user_message}\n\n"
            "[SCOPE] Answer only what was asked above. "
            "Do not call tools beyond those directly required to answer this question."
        )
        messages.append({"role": "user", "content": scoped_message})

        # Determine available tools and iteration budget from intent
        available_tools  = _get_tools_for_intent(intent)
        max_iters        = _get_max_iterations(intent)
        tool_calls_made: list[dict] = []

        logger.info(
            "AgentLoop | intent=%s | tools_available=%d | max_iters=%d",
            intent, len(available_tools), max_iters,
        )
        _trace(
            "agent_start",
            intent=intent,
            tools_available=[t["function"]["name"] for t in available_tools],
            max_iterations=max_iters,
            has_context=bool(context_text.strip()),
            context_chars=len(context_text),
        )

        # If no tools are available for this intent, skip the loop entirely
        if not available_tools:
            logger.debug("No tools for intent=%s — direct generation", intent)
            _trace("direct_generation", reason=f"intent={intent} has no tools")
            t0_gen     = time.monotonic()
            result    = self._call_groq(messages, tools=None)
            gen_ms    = round((time.monotonic() - t0_gen) * 1000, 1)
            raw_text  = result.choices[0].message.content or ""

            # Hallucination guard: model may reference tools it knows about from
            # training even when no tools were offered in this invocation.
            if _has_hallucinated_tool_call(raw_text):
                logger.warning(
                    "Hallucinated tool call detected (intent=%s) — stripping fabricated text",
                    intent,
                )
                _trace("hallucination_guard", action="stripped")
                clean_text = _strip_hallucination(raw_text)
                # If stripping leaves very little content, re-run with explicit instruction
                if len(clean_text.strip()) < 80:
                    messages.append({
                        "role": "assistant",
                        "content": raw_text,
                    })
                    messages.append({
                        "role": "user",
                        "content": (
                            "Note: You referenced tool calls that are not available in "
                            "this context. Please answer using only the retrieved context "
                            "provided above, without mentioning tool calls."
                        ),
                    })
                    retry_result = self._call_groq(messages, tools=None)
                    clean_text   = retry_result.choices[0].message.content or raw_text
                raw_text = clean_text

            _trace("agent_done", iterations=1, duration_ms=gen_ms, response_chars=len(raw_text))
            return AgentResult(
                final_response=raw_text,
                tool_calls_made=[],
                iterations=1,
                requires_approval=False,
            )

        # Execute previously approved tool
        if pending_approval:
            _trace("tool_start", tool=pending_approval["name"],
                   args=pending_approval["args"], approved=True)
            t0_pa = time.monotonic()
            tool_result = self._execute_tool(pending_approval["name"], pending_approval["args"])
            pa_ms = round((time.monotonic() - t0_pa) * 1000, 1)
            _trace("tool_end", tool=pending_approval["name"],
                   duration_ms=pa_ms,
                   result_preview=_preview(tool_result))
            messages.append({
                "role": "tool",
                "content": json.dumps(tool_result, default=str),
                "tool_call_id": pending_approval.get("call_id", "approved_call"),
            })
            tool_calls_made.append({"tool": pending_approval["name"], "approved": True})

        for iteration in range(max_iters):
            _trace("iteration_start", iteration=iteration + 1, max_iterations=max_iters)
            t0_iter = time.monotonic()
            try:
                response = self._call_groq(messages, tools=available_tools)
            except Exception as exc:
                logger.error("Groq call failed at iteration %d: %s", iteration, exc)
                _trace("error", phase_failed="llm_call", error=str(exc))
                return AgentResult(
                    final_response=f"I encountered an error: {exc}. Please try again.",
                    tool_calls_made=tool_calls_made,
                    iterations=iteration + 1,
                    requires_approval=False,
                )
            llm_ms = round((time.monotonic() - t0_iter) * 1000, 1)

            choice = response.choices[0]
            msg    = choice.message

            if not msg.tool_calls:
                _trace("agent_done",
                       iterations=iteration + 1,
                       llm_call_ms=llm_ms,
                       response_chars=len(msg.content or ""))
                return AgentResult(
                    final_response=result_text(msg.content),
                    tool_calls_made=tool_calls_made,
                    iterations=iteration + 1,
                    requires_approval=False,
                )

            messages.append(msg.model_dump(exclude_none=True))

            for tc in msg.tool_calls:
                tool_name = tc.function.name
                try:
                    tool_args = json.loads(tc.function.arguments)
                except json.JSONDecodeError:
                    tool_args = {}

                logger.info("Agent tool call [%s]: %s(%s)", intent, tool_name, tool_args)

                if tool_name in APPROVAL_REQUIRED_TOOLS:
                    _trace("approval_required", tool=tool_name, args=tool_args)
                    return AgentResult(
                        final_response=(
                            f"I need to run `{tool_name}` with parameters: "
                            f"{json.dumps(tool_args)}. "
                            "Please approve or deny this action in the UI."
                        ),
                        tool_calls_made=tool_calls_made,
                        iterations=iteration + 1,
                        requires_approval=True,
                        approval_tool=tool_name,
                        approval_args=tool_args,
                    )

                _trace("tool_start", tool=tool_name, args=tool_args, iteration=iteration + 1)
                t0_tool = time.monotonic()
                tool_result = self._execute_tool(tool_name, tool_args)
                tool_ms = round((time.monotonic() - t0_tool) * 1000, 1)
                _trace("tool_end",
                       tool=tool_name,
                       duration_ms=tool_ms,
                       result_preview=_preview(tool_result),
                       had_error="error" in (tool_result or {}))
                tool_calls_made.append({
                    "tool": tool_name, "args": tool_args, "result": tool_result,
                })
                messages.append({
                    "role":         "tool",
                    "content":      json.dumps(tool_result, default=str),
                    "tool_call_id": tc.id,
                })

        # Per-intent budget exhausted — force synthesis
        logger.warning(
            "Agent reached intent budget (intent=%s max_iters=%d) — forcing synthesis",
            intent, max_iters,
        )
        _trace("synthesis_forced", reason="intent_budget_exhausted", max_iterations=max_iters)
        messages.append({
            "role":    "user",
            "content": "Synthesise your findings into a final answer now.",
        })
        t0_syn = time.monotonic()
        final = self._call_groq(messages, tools=None)
        syn_ms = round((time.monotonic() - t0_syn) * 1000, 1)
        final_text = result_text(final.choices[0].message.content)
        _trace("agent_done",
               iterations=max_iters,
               synthesis_ms=syn_ms,
               response_chars=len(final_text),
               budget_exhausted=True)
        return AgentResult(
            final_response=final_text,
            tool_calls_made=tool_calls_made,
            iterations=max_iters,
            requires_approval=False,
        )

    @retry(
        retry=retry_if_exception_type(RateLimitError),
        stop=stop_after_attempt(4),
        wait=wait_exponential(multiplier=1, min=2, max=30),
        reraise=True,
    )
    def _call_groq(self, messages: list[dict], tools: list[dict] | None):
        return router.complete(
            call_type=CallType.AGENT,
            messages=messages,
            tools=tools or [],
            tool_choice="auto" if tools else "none",
        )

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


def result_text(content: str | None) -> str:
    return content or ""


def _preview(result: Any, limit: int = 220) -> str:
    """Compact, single-line preview of a tool result for the trace UI."""
    try:
        text = json.dumps(result, default=str)
    except Exception:
        text = str(result)
    text = " ".join(text.split())
    return text if len(text) <= limit else text[:limit] + "…"


# ── Hallucination detection ───────────────────────────────────────────────────
import re as _re

_HALLUCINATION_PATTERNS = _re.compile(
    r"(\[Calling\s+\w+|\bI\s+will\s+call\b|\bCalling\s+the\s+(tool|function)\b"
    r"|\[calling\b|\bcalling\s+get_\w+|\bcalling\s+trigger_\w+"
    r"|\blet\s+me\s+call\b|\bI('ll| will)\s+(now\s+)?call\b)",
    _re.I,
)


def _has_hallucinated_tool_call(text: str) -> bool:
    """Return True if the text contains fabricated tool-call language."""
    return bool(_HALLUCINATION_PATTERNS.search(text))


def _strip_hallucination(text: str) -> str:
    """
    Remove fabricated [Calling ...] sentences from response text.
    Replaces with an honest statement about what was retrieved.
    """
    # Remove bracket-style markers
    cleaned = _re.sub(r"\[Calling[^\]]*\]", "", text)
    # Remove "I will call X tool" sentences
    cleaned = _re.sub(
        r"(I\s+will\s+call\s+the\s+`?\w+`?\s+tool[^.]*\.\s*"
        r"|Please\s+wait\s+while\s+I\s+retrieve[^.]*\.\s*"
        r"|Let\s+me\s+(call|retrieve|fetch)[^.]*\.\s*)",
        "",
        cleaned,
        flags=_re.I,
    )
    return cleaned.strip()
