"""Page 1: Streaming Chat"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from ui.components.chat_panel       import render_chat_panel
from ui.components.schema_drift_banner import render_drift_banner

render_drift_banner()
render_chat_panel()
