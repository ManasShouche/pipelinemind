"""
Streaming chat panel component.
Connects to the FastAPI SSE endpoint and renders streamed tokens.
"""
from __future__ import annotations

import json
import httpx
import streamlit as st


API_BASE = "http://localhost:8000"


def _stream_chat(message: str, history: list[dict]) -> dict:
    """
    Call the FastAPI /api/v1/chat SSE endpoint and collect all events.
    Returns the final event payload.
    """
    full_text = ""
    result_event: dict = {}
    approval_event: dict = {}
    retrieval_event: dict = {}

    placeholder = st.empty()

    with httpx.Client(timeout=120) as client:
        with client.stream(
            "POST",
            f"{API_BASE}/api/v1/chat",
            json={"message": message, "conversation_history": history},
        ) as response:
            buffer = ""
            for line in response.iter_lines():
                if line.startswith("event: "):
                    current_event = line[7:]
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
                    elif current_event == "done":
                        result_event = data
                        placeholder.markdown(full_text)
                    elif current_event == "approval_required":
                        approval_event = data
                        placeholder.markdown(data.get("message", ""))

    return {
        "text":      full_text or approval_event.get("message", ""),
        "done":      result_event,
        "retrieval": retrieval_event,
        "approval":  approval_event,
    }


def render_chat_panel() -> None:
    """Main chat panel with conversation history."""
    st.title("PipelineMind — Data Engineering Assistant")

    if "messages" not in st.session_state:
        st.session_state.messages = []

    if "approval_pending" not in st.session_state:
        st.session_state.approval_pending = None

    # Render existing conversation
    for msg in st.session_state.messages:
        with st.chat_message(msg["role"]):
            st.markdown(msg["content"])
            if msg.get("citations"):
                with st.expander("Sources"):
                    for c in msg["citations"]:
                        st.caption(
                            f"[{c['source_index']}] {c['file'].split('/')[-1]} "
                            f"({c['chunk_type']}) — score: {c['score']}"
                        )
            if msg.get("confidence_score") is not None:
                score = msg["confidence_score"]
                color = "green" if score >= 0.7 else ("orange" if score >= 0.5 else "red")
                st.caption(f"Confidence: :{color}[{score:.2f}]")
            if msg.get("pii_warning"):
                st.warning("This response references PII-tagged columns. Handle with care.", icon="🔒")

    # Pending approval gate
    if st.session_state.approval_pending:
        from ui.components.approval_gate import render_approval_gate
        ap = st.session_state.approval_pending
        render_approval_gate(
            tool_name=ap["tool_name"],
            tool_args=ap["tool_args"],
            call_id=ap.get("call_id", "pending"),
        )

    # Chat input
    if prompt := st.chat_input("Ask about your pipelines, data catalogue, or health..."):
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

        ret = result.get("retrieval", {})
        if ret:
            msg_record["confidence_score"] = ret.get("confidence_score")
            msg_record["citations"]        = ret.get("citations", [])
            msg_record["pii_warning"]      = ret.get("has_pii", False)

        if result.get("approval"):
            ap = result["approval"]
            st.session_state.approval_pending = {
                "tool_name": ap.get("tool_name"),
                "tool_args": ap.get("tool_args", {}),
                "call_id":   ap.get("call_id", "pending"),
            }

        st.session_state.messages.append(msg_record)
        st.rerun()
