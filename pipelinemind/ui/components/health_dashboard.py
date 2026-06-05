"""
Pipeline health dashboard component with sparklines.
"""
from __future__ import annotations

import os
from concurrent.futures import ThreadPoolExecutor
import httpx
import pandas as pd
import streamlit as st


API_BASE = os.environ.get("API_BASE_URL", "http://localhost:8000")


@st.cache_data(ttl=60, show_spinner=False)
def _fetch_pipelines() -> list[dict]:
    resp = httpx.get(f"{API_BASE}/api/v1/pipelines", timeout=10)
    return resp.json()


def _fetch_detail(pipeline_id: str) -> tuple[dict, dict]:
    """Fetch status and SLO in parallel for a single pipeline."""
    with ThreadPoolExecutor(max_workers=2) as pool:
        f_status = pool.submit(httpx.get, f"{API_BASE}/api/v1/pipelines/{pipeline_id}/status", timeout=10)
        f_slo    = pool.submit(httpx.get, f"{API_BASE}/api/v1/pipelines/{pipeline_id}/slo",    timeout=10)
    return f_status.result().json(), f_slo.result().json()


def render_health_dashboard() -> None:
    st.header("Pipeline Health Dashboard")

    try:
        pipelines = _fetch_pipelines()
    except Exception as exc:
        st.error(f"Could not reach API: {exc}")
        return

    if not pipelines:
        st.info("No pipeline data available.")
        return

    cols = st.columns(len(pipelines))
    for col, p in zip(cols, pipelines):
        last = p["last_status"]
        delta_color = "normal" if last == "success" else "inverse"
        with col:
            st.metric(
                label=p["pipeline_id"],
                value=f"{p['success_rate']:.1f}%",
                delta=f"Last run: {last}",
                delta_color=delta_color,
            )

    st.divider()

    selected = st.selectbox("Drill into pipeline", [p["pipeline_id"] for p in pipelines])
    if selected:
        try:
            with st.spinner("Loading…"):
                status, slo = _fetch_detail(selected)
        except Exception as exc:
            st.error(f"Failed to fetch details: {exc}")
            return

        c1, c2, c3 = st.columns(3)
        actual    = slo.get("actual_pct")
        compliant = slo.get("compliant")
        c1.metric("Last Status", status.get("status", "N/A"))
        c2.metric("SLO %",       f"{actual:.1f}%" if actual is not None else "N/A")
        c3.metric("Compliant",   "Yes" if compliant else ("No" if compliant is False else "N/A"))

        if status.get("failures"):
            st.subheader("Recent Failures")
            st.dataframe(pd.DataFrame(status["failures"]))
