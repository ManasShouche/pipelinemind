"""
POST /api/v1/chat — SSE streaming chat endpoint.
Routes queries through: intent classification -> RAG retrieval -> agent loop.
Intent is now passed to AgentLoop to enable intent-aware tool filtering.
"""
from __future__ import annotations

import asyncio
import json
import logging
import queue
import time
from datetime import date, datetime
from typing import AsyncGenerator

from fastapi import APIRouter
from fastapi.responses import StreamingResponse

from agent.agent_loop import AgentLoop
from api.models import ChatRequest, ToolApprovalRequest
from retrieval.hybrid_retriever import HybridRetriever
from retrieval.intent_classifier import Intent

logger = logging.getLogger(__name__)
router  = APIRouter()

_retriever = HybridRetriever()
_agent     = AgentLoop()


def _json_default(obj: object) -> str:
    """Fallback JSON serialiser for datetime/date objects in SSE payloads."""
    if isinstance(obj, (datetime, date)):
        return obj.isoformat()
    return str(obj)


_AGENT_TRACE_SENTINEL = object()


async def _event_stream(
    message: str,
    context_text: str,
    conversation_history: list[dict],
    confidence_score: float,
    has_pii: bool,
    citations: list[dict],
    low_confidence: bool,
    intent: str | None,
    intent_confidence: float,
    hyde_query: str,
    original_query: str,
    raw_chunk_count: int,
) -> AsyncGenerator[str, None]:
    """Yield SSE-formatted events during retrieval and agent execution."""

    def _sse(event: str, data: dict) -> str:
        return f"event: {event}\ndata: {json.dumps(data, default=_json_default)}\n\n"

    # ── Retrieval-phase trace events (emitted post-hoc from RetrievalResult) ──
    yield _sse("trace", {
        "phase":      "intent_classified",
        "intent":     intent,
        "confidence": round(intent_confidence, 3),
    })
    await asyncio.sleep(0)

    if hyde_query and hyde_query != original_query:
        yield _sse("trace", {
            "phase":         "hyde_generated",
            "hyde_chars":    len(hyde_query),
            "hyde_preview":  hyde_query[:160] + ("…" if len(hyde_query) > 160 else ""),
        })
        await asyncio.sleep(0)

    yield _sse("trace", {
        "phase":            "retrieval_complete",
        "chunks_retrieved": raw_chunk_count,
        "chunks_used":      len(citations),
        "top_score":        round(citations[0]["score"], 4) if citations else 0.0,
        "low_confidence":   low_confidence,
        "has_pii":          has_pii,
    })
    await asyncio.sleep(0)

    # The existing UI listens on `retrieval_complete` — keep emitting it
    # so the citations panel and confidence pill stay populated.
    yield _sse("retrieval_complete", {
        "confidence_score": round(confidence_score, 3),
        "has_pii":          has_pii,
        "citations":        citations,
        "low_confidence":   low_confidence,
        "intent":           intent,
    })
    await asyncio.sleep(0)

    # ── Bridge: agent runs in executor, pushes trace events into a queue ──
    trace_q: "queue.Queue[dict | object]" = queue.Queue()

    def _on_trace(event: dict) -> None:
        trace_q.put(event)

    loop = asyncio.get_event_loop()
    start = time.monotonic()
    agent_future = loop.run_in_executor(
        None,
        lambda: _agent.run(
            user_message=message,
            context_text=context_text,
            conversation_history=conversation_history,
            intent=intent,
            trace_callback=_on_trace,
        ),
    )
    # Sentinel posted when the agent finishes so the drain loop below exits.
    agent_future.add_done_callback(lambda _f: trace_q.put(_AGENT_TRACE_SENTINEL))

    # Stream trace events as the agent emits them.
    while True:
        try:
            evt = trace_q.get_nowait()
        except queue.Empty:
            if agent_future.done():
                # Drain any final items the callback posted between checks.
                while not trace_q.empty():
                    evt = trace_q.get_nowait()
                    if evt is _AGENT_TRACE_SENTINEL:
                        break
                    yield _sse("trace", evt)
                break
            await asyncio.sleep(0.02)
            continue
        if evt is _AGENT_TRACE_SENTINEL:
            break
        yield _sse("trace", evt)

    result  = await agent_future
    latency = round((time.monotonic() - start) * 1000, 2)

    if result.requires_approval:
        yield _sse("approval_required", {
            "tool_name":  result.approval_tool,
            "tool_args":  result.approval_args,
            "message":    result.final_response,
            "latency_ms": latency,
        })
        return

    words      = result.final_response.split()
    chunk_size = max(1, len(words) // 20)
    for i in range(0, len(words), chunk_size):
        chunk = " ".join(words[i : i + chunk_size])
        yield _sse("token", {"text": chunk + " "})
        await asyncio.sleep(0.02)

    yield _sse("done", {
        "full_response": result.final_response,
        "tool_calls":    result.tool_calls_made,
        "iterations":    result.iterations,
        "latency_ms":    latency,
    })


@router.post("/chat")
async def chat(request: ChatRequest):
    """Main chat endpoint with SSE streaming."""
    logger.info("Chat | '%s...'", request.message[:80])

    intent_override = None
    if request.intent_override:
        try:
            intent_override = Intent(request.intent_override)
        except ValueError:
            pass

    retrieval = _retriever.retrieve(
        query=request.message,
        intent_override=intent_override,
        metadata_filters=(
            {"pipeline_name": request.pipeline_filter}
            if request.pipeline_filter
            else None
        ),
    )

    # Pass intent string to event stream so AgentLoop can filter tools
    intent_str = retrieval.intent.value if retrieval.intent else None

    return StreamingResponse(
        _event_stream(
            message=request.message,
            context_text=retrieval.context.context_text,
            conversation_history=request.conversation_history,
            confidence_score=retrieval.context.confidence_score,
            has_pii=retrieval.context.has_pii,
            citations=retrieval.context.citations,
            low_confidence=retrieval.context.low_confidence,
            intent=intent_str,
            intent_confidence=retrieval.intent_confidence,
            hyde_query=retrieval.hyde_query,
            original_query=retrieval.original_query,
            raw_chunk_count=len(retrieval.raw_chunks),
        ),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@router.post("/chat/approve")
async def approve_tool(request: ToolApprovalRequest):
    """Human-in-the-loop approval gate for state-altering tool calls."""
    if not request.approved:
        return {"status": "denied", "message": "Tool execution denied by user."}

    result = await asyncio.get_event_loop().run_in_executor(
        None,
        lambda: _agent.run(
            user_message=f"Execute the approved tool call: {request.tool_name}",
            pending_approval={
                "name":    request.tool_name,
                "args":    request.tool_args,
                "call_id": request.call_id,
            },
            intent="ACTION",  # approved tool calls are always ACTION intent
        ),
    )
    return {
        "status":     "executed",
        "result":     result.final_response,
        "tool_calls": result.tool_calls_made,
    }
