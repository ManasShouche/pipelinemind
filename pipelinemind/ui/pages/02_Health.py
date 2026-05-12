"""Page 2: Pipeline Health Dashboard"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from ui.components.health_dashboard    import render_health_dashboard
from ui.components.schema_drift_banner import render_drift_banner

render_drift_banner()
render_health_dashboard()
