"""
Pipeline health dashboard component with sparklines.
"""
from __future__ import annotations

import os
import httpx
import pandas as pd
import streamlit as st


API_BASE = os.environ.get("API_BASE_URL", "http://localhost:8000")


def render_health_dashboard() -> None:
    st.header("Pipeline Health Dashboard")

    try:
        resp = httpx.get(f"{API_BASE}/api/v1/pipelines", timeout=10)
        pipelines = resp.json()
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
            status_resp = httpx.get(f"{API_BASE}/api/v1/pipelines/{selected}/status", timeout=10)
            slo_resp    = httpx.get(f"{API_BASE}/api/v1/pipelines/{selected}/slo", timeout=10)
            status = status_resp.json()
            slo    = slo_resp.json()
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
