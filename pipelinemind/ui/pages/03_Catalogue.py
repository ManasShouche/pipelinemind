"""Page 3: Data Catalogue Browser"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent.parent))

import httpx
import streamlit as st
from ui.components.lineage_graph       import render_lineage_graph
from ui.components.schema_drift_banner import render_drift_banner

render_drift_banner()
API_BASE = "http://localhost:8000"

st.header("Data Catalogue Browser")

try:
    tables = httpx.get(f"{API_BASE}/api/v1/catalogue/tables", timeout=10).json()
except Exception as exc:
    st.error(f"API unavailable: {exc}")
    tables = []

if tables:
    pii_tables = [t for t in tables if t.get("pii_flag")]
    if pii_tables:
        st.warning(f"{len(pii_tables)} table(s) contain PII columns.", icon="🔒")

    selected = st.selectbox("Select a table", [t["table_name"] for t in tables])
    if selected:
        try:
            detail = httpx.get(f"{API_BASE}/api/v1/catalogue/tables/{selected}", timeout=10).json()
            tbl = detail.get("table", {})
            cols = detail.get("columns", [])

            c1, c2, c3 = st.columns(3)
            c1.metric("Domain", tbl.get("domain", "N/A"))
            c2.metric("Rows", f"{tbl.get('row_count', 0):,}")
            c3.metric("PII", "Yes" if tbl.get("pii_flag") else "No")

            st.markdown(f"**Description:** {tbl.get('description', 'N/A')}")

            import pandas as pd
            st.dataframe(pd.DataFrame(cols), use_container_width=True)

            st.subheader("Lineage DAG")
            depth = st.slider("Lineage depth", 1, 4, 2)
            render_lineage_graph(selected, depth)

        except Exception as exc:
            st.error(f"Failed to load table detail: {exc}")
