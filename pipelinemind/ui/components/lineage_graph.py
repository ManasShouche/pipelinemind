"""
Interactive lineage DAG component using streamlit-agraph.
"""
from __future__ import annotations

import os
import httpx
import streamlit as st

try:
    from streamlit_agraph import agraph, Node, Edge, Config
    AGRAPH_AVAILABLE = True
except ImportError:
    AGRAPH_AVAILABLE = False

API_BASE = os.environ.get("API_BASE_URL", "http://localhost:8000")


def render_lineage_graph(table_name: str, depth: int = 2) -> None:
    try:
        resp = httpx.get(
            f"{API_BASE}/api/v1/catalogue/lineage/{table_name}",
            params={"depth": depth}, timeout=10,
        )
        data = resp.json()
    except Exception as exc:
        st.error(f"Failed to fetch lineage: {exc}")
        return

    if not AGRAPH_AVAILABLE:
        st.warning("streamlit-agraph not installed. Showing raw lineage data.")
        st.json(data)
        return

    nodes_data = data.get("nodes", [])
    edges_data = data.get("edges", [])
    pii_nodes  = set(data.get("pii_nodes", []))

    nodes = []
    for n in nodes_data:
        is_center = n["table"] == table_name
        is_pii    = n["table"] in pii_nodes
        if is_pii:
            bg, font_color = "#FF4B4B", "#FFFFFF"
        elif is_center:
            bg, font_color = "#FFD700", "#111111"
        else:
            bg, font_color = "#4B8BFF", "#FFFFFF"

        nodes.append(Node(
            id=n["table"],
            label=n["table"],
            size=28 if is_center else 22,
            color=bg,
            font={"color": font_color, "size": 13, "face": "monospace"},
            title=f"Domain: {n.get('domain','?')} | Rows: {n.get('row_count',0):,}",
            borderWidth=3 if is_center else 1,
            borderWidthSelected=4,
        ))

    edges = [
        Edge(
            source=e["source"],
            target=e["target"],
            label=e.get("transformation", ""),
            font={"size": 10, "color": "#888888", "align": "middle"},
            color={"color": "#aaaaaa", "highlight": "#555555"},
            arrows="to",
        )
        for e in edges_data
    ]

    config = Config(
        width="100%",
        height=520,
        directed=True,
        physics=True,
        hierarchical=False,
        nodeHighlightBehavior=True,
        highlightColor="#F7A7A6",
        collapsible=False,
        node={"labelHighlightBold": True},
        link={"renderLabel": True},
        d3={"gravity": -300, "linkLength": 180},
    )
    agraph(nodes=nodes, edges=edges, config=config)

    if pii_nodes:
        st.warning(f"PII-tagged nodes: {', '.join(pii_nodes)}", icon="🔒")
