"""
Streaming chat panel component.
Connects to the FastAPI SSE endpoint and renders streamed tokens.

Citation display:
  - Scores shown as percentage (sigmoid-normalised, 0–100%)
  - Citations below 10% hidden (irrelevant documents)
  - Graph-augmented chunks marked with a 🔗 lineage badge
  - PII warning only shown when a PII_HIGH column is explicitly referenced
"""
from __future__ import annotations

import json
import os
import httpx
import streamlit as st

API_BASE          = os.environ.get("API_BASE_URL", "http://localhost:8000")
MIN_DISPLAY_SCORE = 0.10

_SUGGESTIONS = [
    "Why does the orders pipeline use MERGE?",
    "What PII is in dim_users?",
    "What happens if I drop user_id from stg_users?",
    "Did the orders pipeline fail today?",
]

_INTENT_COLOURS = {
    "CODE_QA":   ("🔍", "#1f77b4"),
    "CATALOGUE": ("📂", "#2ca02c"),
    "HEALTH":    ("💚", "#17becf"),
    "ACTION":    ("⚡", "#ff7f0e"),
    "GENERAL":   ("💬", "#7f7f7f"),
}


def _stream_chat(message: str, history: list[dict]) -> dict:
    """
    Call the FastAPI /api/v1/chat SSE endpoint and collect all events.
    Returns the final event payload, including the live agent trace.
    """
    full_text        = ""
    result_event     = {}
    approval_event   = {}
    retrieval_event  = {}
    trace_events: list[dict] = []
    current_event    = ""

    placeholder       = st.empty()
    trace_placeholder = st.empty()

    with httpx.Client(timeout=120) as client:
        with client.stream(
            "POST",
            f"{API_BASE}/api/v1/chat",
            json={"message": message, "conversation_history": history},
        ) as response:
            for line in response.iter_lines():
                if line.startswith("event: "):
                    current_event = line[7:].strip()
                elif line.startswith("data: "):
                    data_str = line[6:]
                    try:
                        data = json.loads(data_str)
                    except json.JSONDecodeError:
                        continue

                    if current_event == "token":
                        full_text += data.get("text", "")
                        placeholder.markdown(full_text + "▌")
                    elif current_event == "retrieval_complete":
                        retrieval_event = data
                    elif current_event == "trace":
                        trace_events.append(data)
                        _render_live_trace(trace_placeholder, trace_events)
                    elif current_event == "done":
                        result_event = data
                        placeholder.markdown(full_text)
                    elif current_event == "approval_required":
                        approval_event = data
                        placeholder.markdown(data.get("message", ""))

    trace_placeholder.empty()

    return {
        "text":      full_text or approval_event.get("message", ""),
        "done":      result_event,
        "retrieval": retrieval_event,
        "trace":     trace_events,
        "approval":  approval_event,
    }


# ── Agent Trace rendering ────────────────────────────────────────────────────

_PHASE_ICONS = {
    "intent_classified":   "→",
    "hyde_generated":      "~",
    "retrieval_complete":  "↩",
    "agent_start":         "▶",
    "direct_generation":   "▶",
    "iteration_start":     "·",
    "tool_start":          "⤷",
    "tool_end":            "✓",
    "approval_required":   "⏸",
    "hallucination_guard": "!",
    "synthesis_forced":    "·",
    "agent_done":          "■",
    "error":               "✗",
}


def _format_trace_line(evt: dict) -> str:
    phase = evt.get("phase", "")
    icon  = _PHASE_ICONS.get(phase, "•")
    if phase == "intent_classified":
        return f"{icon} **Intent** — `{evt.get('intent')}` (confidence {evt.get('confidence')})"
    if phase == "hyde_generated":
        return (
            f"{icon} **HyDE** — generated {evt.get('hyde_chars')} chars: "
            f"_{evt.get('hyde_preview', '')}_"
        )
    if phase == "retrieval_complete":
        flags = []
        if evt.get("low_confidence"): flags.append("low-confidence")
        if evt.get("has_pii"):        flags.append("PII")
        suffix = f" — flags: {', '.join(flags)}" if flags else ""
        return (
            f"{icon} **Retrieval** — {evt.get('chunks_retrieved')} retrieved, "
            f"{evt.get('chunks_used')} used, top score {evt.get('top_score')}{suffix}"
        )
    if phase == "agent_start":
        tools = evt.get("tools_available") or []
        tools_str = ", ".join(f"`{t}`" for t in tools) if tools else "_none_"
        return (
            f"{icon} **Agent start** — intent=`{evt.get('intent')}`, "
            f"budget={evt.get('max_iterations')} iters, tools: {tools_str}"
        )
    if phase == "direct_generation":
        return f"{icon} **Direct generation** — {evt.get('reason', '')}"
    if phase == "iteration_start":
        return f"{icon} **Iteration {evt.get('iteration')}/{evt.get('max_iterations')}**"
    if phase == "tool_start":
        return (
            f"{icon} **Tool call** — `{evt.get('tool')}`"
            f"({json.dumps(evt.get('args', {}))})"
        )
    if phase == "tool_end":
        err = " ❌" if evt.get("had_error") else ""
        return (
            f"{icon} **Tool result** — `{evt.get('tool')}` in "
            f"{evt.get('duration_ms')}ms{err} — `{evt.get('result_preview', '')}`"
        )
    if phase == "approval_required":
        return f"{icon} **Approval gate** — `{evt.get('tool')}` paused for human review"
    if phase == "hallucination_guard":
        return f"{icon} **Hallucination guard** — {evt.get('action', '')}"
    if phase == "synthesis_forced":
        return f"{icon} **Synthesis forced** — {evt.get('reason', '')}"
    if phase == "agent_done":
        bits = [f"{evt.get('iterations')} iter"]
        if evt.get("llm_call_ms"):    bits.append(f"llm {evt['llm_call_ms']}ms")
        if evt.get("synthesis_ms"):   bits.append(f"synth {evt['synthesis_ms']}ms")
        if evt.get("duration_ms"):    bits.append(f"{evt['duration_ms']}ms")
        if evt.get("response_chars"): bits.append(f"{evt['response_chars']} chars")
        return f"{icon} **Done** — " + " · ".join(bits)
    if phase == "error":
        return f"{icon} **Error** — {evt.get('phase_failed')}: {evt.get('error')}"
    return f"{icon} {phase} — {json.dumps({k: v for k, v in evt.items() if k != 'phase'})}"


def _render_live_trace(slot, events: list[dict]) -> None:
    if not events:
        return
    lines = [_format_trace_line(e) for e in events]
    slot.markdown(
        "**Agent reasoning…**\n\n" + "\n\n".join(f"- {ln}" for ln in lines)
    )


def _render_trace(events: list[dict]) -> None:
    if not events:
        return
    with st.expander(f"Agent trace ({len(events)} steps)"):
        for evt in events:
            st.markdown("- " + _format_trace_line(evt))


# ── Citations ────────────────────────────────────────────────────────────────

def _relevance_bar(pct: float) -> str:
    """Return a simple text progress bar for relevance score."""
    filled = round(pct / 10)
    return "█" * filled + "░" * (10 - filled)


def _render_citations(citations: list[dict]) -> None:
    visible = [c for c in citations if c.get("score", 0) >= MIN_DISPLAY_SCORE]
    if not visible:
        return

    graph_count = sum(1 for c in visible if c.get("retrieval_method") == "graph")
    label = f"Sources ({len(visible)} relevant"
    if graph_count:
        label += f", {graph_count} via lineage graph 🔗"
    label += ")"

    with st.expander(label):
        rag_chunks   = [c for c in visible if c.get("retrieval_method") != "graph"]
        graph_chunks = [c for c in visible if c.get("retrieval_method") == "graph"]

        if rag_chunks:
            for c in rag_chunks:
                _render_citation_row(c)

        if graph_chunks:
            st.markdown("**🔗 Lineage graph neighbours**")
            for c in graph_chunks:
                _render_citation_row(c, is_graph=True)


def _render_citation_row(c: dict, is_graph: bool = False) -> None:
    score_pct = round(c.get("score", 0) * 100, 1)
    file_name = c.get("file", "").split("/")[-1] or "unknown"
    chunk_type = c.get("chunk_type", "")
    fn         = c.get("function_name", "")
    git_hash   = c.get("git_commit_hash", "")

    parts = [f"**[{c['source_index']}]** `{file_name}`"]
    if chunk_type:
        tag = chunk_type
        if fn:
            tag += f" · {fn}"
        parts.append(f"_{tag}_")
    if git_hash:
        parts.append(f"`git:{git_hash[:7]}`")
    if is_graph:
        parts.append("🔗 _lineage graph_")

    bar  = _relevance_bar(score_pct)
    cols = st.columns([5, 2])
    with cols[0]:
        st.markdown(" &nbsp;·&nbsp; ".join(parts), unsafe_allow_html=True)
    with cols[1]:
        if score_pct >= 70:
            st.markdown(f":green[{bar}] **{score_pct}%**")
        elif score_pct >= 40:
            st.markdown(f":orange[{bar}] **{score_pct}%**")
        else:
            st.markdown(f":gray[{bar}] {score_pct}%")


# ── Intent + Confidence pills ────────────────────────────────────────────────

def _render_meta_pills(intent: str | None, confidence: float | None) -> None:
    """Render intent badge and confidence pill side by side."""
    cols = st.columns([2, 2, 6])

    if intent:
        icon, _ = _INTENT_COLOURS.get(intent, ("•", "#888"))
        with cols[0]:
            st.markdown(f"{icon} **`{intent}`**")

    if confidence is not None:
        pct = round(confidence * 100, 1)
        with cols[1]:
            if confidence >= 0.7:
                st.markdown(f":green[● **{pct}% confidence**]")
            elif confidence >= 0.5:
                st.markdown(f":orange[● **{pct}% confidence**]")
            else:
                st.markdown(f":red[● **{pct}%** — low confidence]")


# ── Empty state ──────────────────────────────────────────────────────────────

def _render_empty_state() -> str | None:
    """Show suggestion chips; return the clicked suggestion or None."""
    st.markdown("### 👋 What do you want to know about your pipelines?")
    st.caption("Try one of these or type your own question below.")
    st.write("")
    cols = st.columns(2)
    for i, suggestion in enumerate(_SUGGESTIONS):
        if cols[i % 2].button(suggestion, key=f"sug_{i}", use_container_width=True):
            return suggestion
    return None


# ── Main panel ───────────────────────────────────────────────────────────────

def render_chat_panel() -> None:
    st.title("PipelineMind — Data Engineering Assistant")

    if "messages" not in st.session_state:
        st.session_state.messages = []
    if "approval_pending" not in st.session_state:
        st.session_state.approval_pending = None

    # Sidebar controls
    st.sidebar.divider()
    if st.sidebar.button("🗑️ Clear conversation", use_container_width=True):
        st.session_state.messages = []
        st.session_state.approval_pending = None
        st.rerun()

    # Empty state → suggestion chips
    suggestion_clicked: str | None = None
    if not st.session_state.messages:
        suggestion_clicked = _render_empty_state()
        if suggestion_clicked:
            st.session_state._pending_suggestion = suggestion_clicked
            st.rerun()

    # Pull a suggestion that was clicked on the previous rerun
    injected_prompt: str | None = None
    if "_pending_suggestion" in st.session_state:
        injected_prompt = st.session_state.pop("_pending_suggestion")

    # Render existing conversation history
    for msg in st.session_state.messages:
        with st.chat_message(msg["role"]):
            st.markdown(msg["content"])
            if msg["role"] == "assistant":
                _render_meta_pills(msg.get("intent"), msg.get("confidence_score"))
                if msg.get("citations"):
                    _render_citations(msg["citations"])
                if msg.get("pii_warning"):
                    st.warning(
                        "Response references PII columns (email, phone, date_of_birth). "
                        "Handle with care.",
                        icon="🔒",
                    )
                if msg.get("trace"):
                    _render_trace(msg["trace"])

    # Pending approval gate
    if st.session_state.approval_pending:
        from ui.components.approval_gate import render_approval_gate
        ap = st.session_state.approval_pending
        render_approval_gate(
            tool_name=ap["tool_name"],
            tool_args=ap["tool_args"],
            call_id=ap.get("call_id", "pending"),
        )

    # Accept input (either from chat box or injected suggestion)
    prompt = injected_prompt or st.chat_input(
        "Ask about your pipelines, data catalogue, or health..."
    )

    if prompt:
        st.session_state.messages.append({"role": "user", "content": prompt})
        with st.chat_message("user"):
            st.markdown(prompt)

        with st.chat_message("assistant"):
            history = [
                {"role": m["role"], "content": m["content"]}
                for m in st.session_state.messages[:-1]
            ]
            try:
                result = _stream_chat(prompt, history)
            except Exception as exc:
                st.error(f"Connection error: {exc}")
                return

        msg_record: dict = {"role": "assistant", "content": result["text"]}

        if result.get("trace"):
            msg_record["trace"] = result["trace"]

        ret = result.get("retrieval", {})
        if ret:
            raw_citations = ret.get("citations", [])
            msg_record["citations"]        = [
                c for c in raw_citations if c.get("score", 0) >= MIN_DISPLAY_SCORE
            ]
            msg_record["confidence_score"] = ret.get("confidence_score")
            msg_record["intent"]           = ret.get("intent")
            top_score = ret.get("confidence_score", 0)
            msg_record["pii_warning"] = ret.get("has_pii", False) and top_score >= 0.5

        if result.get("approval"):
            ap = result["approval"]
            st.session_state.approval_pending = {
                "tool_name": ap.get("tool_name"),
                "tool_args": ap.get("tool_args", {}),
                "call_id":   ap.get("call_id", "pending"),
            }

        st.session_state.messages.append(msg_record)
        st.rerun()
