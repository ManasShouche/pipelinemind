"""
PipelineMind Streamlit entry point.
Multi-page app: Chat | Health | Catalogue
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import streamlit as st

st.set_page_config(
    page_title="PipelineMind",
    page_icon="PM",
    layout="wide",
    initial_sidebar_state="expanded",
)

from ui.components.schema_drift_banner import render_drift_banner
from ui.components.chat_panel import render_chat_panel

render_drift_banner()

st.sidebar.title("PipelineMind")
st.sidebar.markdown("RAG-Powered Data Engineering Assistant")
st.sidebar.divider()
st.sidebar.markdown(
    """
    **Quick shortcuts**
    - `/diagnose_pipeline orders`
    - Ask: *Why does orders use MERGE?*
    - Ask: *What PII is in dim_users?*
    - Ask: *What happens if I drop user_id from stg_users?*
    """
)

render_chat_panel()
