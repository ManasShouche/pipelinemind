"""
Smoke test for the Agent Trace Panel feature.

Drives `_event_stream` directly with stubs for HybridRetriever and AgentLoop,
asserts the SSE wire format contains every expected trace phase + the
backward-compatible retrieval_complete + token + done events.

Run from the project root:
    .venv/bin/python scripts/smoke_trace.py
"""
from __future__ import annotations

import asyncio
import json
import sys
import time
from pathlib import Path

# Add project root to sys.path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

# Pre-stub the heavy dependencies so we can import the chat router
# without booting Chroma, sentence-transformers, etc.
import types

# Patch HybridRetriever before chat.py imports it.
import retrieval.hybrid_retriever as hr_mod
import agent.agent_loop as al_mod


class _StubBuiltContext:
    def __init__(self) -> None:
        self.context_text     = "[SOURCE 1] orders_pipeline.py (python | merge_strategy)\n```\n…\n```"
        self.confidence_score = 0.81
        self.has_pii          = False
        self.low_confidence   = False
        self.citations        = [
            {"source_index": 1, "file": "data/pipeline_repo/orders_pipeline.py",
             "chunk_type": "python", "function_name": "merge_strategy",
             "git_commit_hash": "abc1234", "score": 0.81},
        ]


class _StubRetrievalResult:
    def __init__(self, intent_value: str) -> None:
        # Mimic the real Intent enum
        self.intent             = types.SimpleNamespace(value=intent_value)
        self.intent_confidence  = 0.95
        self.context            = _StubBuiltContext()
        self.raw_chunks         = list(range(5))   # only length is read
        self.hyde_query         = "A hypothetical document about how orders pipeline uses MERGE to upsert into the warehouse..."
        self.original_query     = "How does the orders pipeline use MERGE?"


class _StubHybridRetriever:
    def retrieve(self, query, intent_override=None, metadata_filters=None):
        return _StubRetrievalResult("CATALOGUE")


class _StubAgentResult:
    def __init__(self, text: str) -> None:
        self.final_response   = text
        self.tool_calls_made  = [
            {"tool": "get_lineage_graph",
             "args": {"table_name": "stg_orders", "depth": 2},
             "result": {"upstream": ["raw_orders"], "downstream": ["fct_orders"]}},
        ]
        self.iterations       = 1
        self.requires_approval = False
        self.approval_tool    = ""
        self.approval_args    = {}


class _StubAgentLoop:
    def run(self, user_message, context_text="", conversation_history=None,
            pending_approval=None, intent=None, trace_callback=None):
        """Emit a representative sequence of trace events synchronously."""
        def _emit(phase, **payload):
            if trace_callback is not None:
                trace_callback({"phase": phase, **payload})

        _emit("agent_start", intent=intent,
              tools_available=["get_lineage_graph", "search_pii_tables"],
              max_iterations=1, has_context=True, context_chars=len(context_text))
        _emit("iteration_start", iteration=1, max_iterations=1)
        _emit("tool_start", tool="get_lineage_graph",
              args={"table_name": "stg_orders", "depth": 2}, iteration=1)
        time.sleep(0.02)
        _emit("tool_end", tool="get_lineage_graph", duration_ms=18.4,
              result_preview='{"upstream": ["raw_orders"], "downstream": ["fct_orders"]}',
              had_error=False)
        _emit("agent_done", iterations=1, llm_call_ms=812.5, response_chars=240)

        return _StubAgentResult(
            "stg_orders has 1 upstream (raw_orders) and 1 downstream (fct_orders). "
            "It uses MERGE to upsert by order_id."
        )


# Install stubs before importing chat.py.
hr_mod.HybridRetriever = _StubHybridRetriever
al_mod.AgentLoop       = _StubAgentLoop

# Now import the router and run the generator end-to-end.
from api.routers import chat as chat_mod

# Replace the module-level singletons that chat.py captured at import time.
chat_mod._retriever = _StubHybridRetriever()
chat_mod._agent     = _StubAgentLoop()


async def drive() -> list[str]:
    retrieval = chat_mod._retriever.retrieve("How does the orders pipeline use MERGE?")
    gen = chat_mod._event_stream(
        message              = "How does the orders pipeline use MERGE?",
        context_text         = retrieval.context.context_text,
        conversation_history = [],
        confidence_score     = retrieval.context.confidence_score,
        has_pii              = retrieval.context.has_pii,
        citations            = retrieval.context.citations,
        low_confidence       = retrieval.context.low_confidence,
        intent               = retrieval.intent.value,
        intent_confidence    = retrieval.intent_confidence,
        hyde_query           = retrieval.hyde_query,
        original_query       = retrieval.original_query,
        raw_chunk_count      = len(retrieval.raw_chunks),
    )
    chunks: list[str] = []
    async for ch in gen:
        chunks.append(ch)
    return chunks


def parse_sse(chunks: list[str]) -> list[tuple[str, dict]]:
    events: list[tuple[str, dict]] = []
    for raw in chunks:
        lines = raw.splitlines()
        event_name = None
        data_str   = None
        for ln in lines:
            if ln.startswith("event: "):
                event_name = ln[7:].strip()
            elif ln.startswith("data: "):
                data_str = ln[6:]
        if event_name and data_str is not None:
            try:
                events.append((event_name, json.loads(data_str)))
            except json.JSONDecodeError:
                events.append((event_name, {"_raw": data_str}))
    return events


def main() -> int:
    raw_chunks = asyncio.run(drive())
    events     = parse_sse(raw_chunks)

    print(f"\n── Got {len(events)} SSE events ──\n")
    for i, (name, data) in enumerate(events, start=1):
        if name == "token":
            preview = data.get("text", "")[:40].replace("\n", " ")
            print(f"  [{i:02d}] {name:22s}  text='{preview}…'")
        elif name == "trace":
            phase = data.get("phase", "?")
            keys  = ", ".join(k for k in data if k != "phase")
            print(f"  [{i:02d}] {name:22s}  phase={phase}  ({keys})")
        else:
            keys = ", ".join(data.keys())
            print(f"  [{i:02d}] {name:22s}  ({keys})")

    # ── Assertions ────────────────────────────────────────────────────
    expected_phases = {
        "intent_classified", "hyde_generated", "retrieval_complete",
        "agent_start", "iteration_start", "tool_start", "tool_end", "agent_done",
    }
    seen_phases = {d.get("phase") for name, d in events if name == "trace"}
    missing = expected_phases - seen_phases
    assert not missing, f"Missing trace phases: {missing}"
    print("\nOK: every expected trace phase fired:", sorted(seen_phases))

    event_names = [name for name, _ in events]
    assert "retrieval_complete" in event_names, "back-compat retrieval_complete event missing"
    assert event_names.count("token") >= 1, "no token events streamed"
    assert event_names[-1] == "done", f"last event must be 'done', got {event_names[-1]}"
    done_payload = events[-1][1]
    assert done_payload["iterations"] == 1
    assert done_payload["tool_calls"][0]["tool"] == "get_lineage_graph"
    assert isinstance(done_payload["latency_ms"], (int, float))
    print("OK: backward-compat retrieval_complete present")
    print("OK: tokens streamed, done event has tool_calls + latency_ms")

    # Phase ordering — agent_start must come after retrieval_complete trace,
    # tool_end must come after tool_start, agent_done must be last trace.
    trace_phases_in_order = [d["phase"] for name, d in events if name == "trace"]
    assert trace_phases_in_order.index("retrieval_complete") < trace_phases_in_order.index("agent_start")
    assert trace_phases_in_order.index("tool_start") < trace_phases_in_order.index("tool_end")
    assert trace_phases_in_order[-1] == "agent_done", trace_phases_in_order
    print("OK: trace phase ordering preserved (retrieval → agent_start → tools → agent_done)")

    print("\nALL SMOKE CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
