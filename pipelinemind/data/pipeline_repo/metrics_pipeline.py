"""
KPI metrics computation pipeline with SLO tracking.
Computes daily business KPIs (GMV, DAU, Conversion Rate, Avg Order Value)
from warehouse tables and writes to the kpi_daily_metrics table.
Evaluates against SLO thresholds and emits breach events.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from typing import Any

import pandas as pd
from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine

logger = logging.getLogger(__name__)

KPI_DEFINITIONS: dict[str, dict[str, Any]] = {
    "gmv_usd": {
        "description": "Gross Merchandise Value in USD",
        "slo_min": 50_000.0,
        "alert_on": "below",
    },
    "daily_active_users": {
        "description": "Unique users with at least one session",
        "slo_min": 500,
        "alert_on": "below",
    },
    "conversion_rate_pct": {
        "description": "Orders / Sessions * 100",
        "slo_min": 2.0,
        "slo_max": 15.0,
        "alert_on": "both",
    },
    "avg_order_value_usd": {
        "description": "GMV / total orders",
        "slo_min": 30.0,
        "alert_on": "below",
    },
    "cart_abandonment_rate_pct": {
        "description": "Abandoned carts / total cart initiations * 100",
        "slo_max": 75.0,
        "alert_on": "above",
    },
}


@dataclass
class SLOBreach:
    kpi_name: str
    actual_value: float
    slo_threshold: float
    breach_type: str  # "below_min" | "above_max"
    metric_date: date


class MetricsPipeline:
    """
    Daily KPI computation pipeline.

    Reads from the warehouse layer (orders_fact, sessions_agg, dim_users),
    computes composite business metrics, evaluates SLO thresholds,
    and writes to kpi_daily_metrics with breach event logging.
    """

    def __init__(self, warehouse_conn: str) -> None:
        self.engine: Engine = create_engine(warehouse_conn, pool_pre_ping=True)

    def compute_gmv(self, metric_date: date) -> float:
        """Sum of total_amount for delivered/confirmed orders on metric_date."""
        result = self.engine.execute(
            text(
                """
                SELECT COALESCE(SUM(total_amount), 0.0) AS gmv
                FROM orders_fact
                WHERE order_date = :d
                  AND order_status IN ('confirmed', 'shipped', 'delivered')
                """
            ),
            {"d": metric_date},
        ).scalar()
        return float(result)

    def compute_dau(self, metric_date: date) -> int:
        """Count of unique users with at least one session on metric_date."""
        result = self.engine.execute(
            text(
                """
                SELECT COUNT(DISTINCT user_id) AS dau
                FROM sessions_agg
                WHERE DATE(session_start) = :d
                """
            ),
            {"d": metric_date},
        ).scalar()
        return int(result or 0)

    def compute_conversion_rate(self, metric_date: date, dau: int) -> float:
        """Orders / DAU * 100, guard against division by zero."""
        if dau == 0:
            return 0.0
        orders = self.engine.execute(
            text(
                """
                SELECT COUNT(*) FROM orders_fact
                WHERE order_date = :d AND status_code >= 1
                """
            ),
            {"d": metric_date},
        ).scalar()
        return round((float(orders) / dau) * 100, 4)

    def compute_aov(self, metric_date: date, gmv: float) -> float:
        """Average order value = GMV / total orders."""
        orders = self.engine.execute(
            text(
                "SELECT COUNT(*) FROM orders_fact WHERE order_date = :d AND status_code >= 1"
            ),
            {"d": metric_date},
        ).scalar()
        return round(gmv / orders, 2) if orders else 0.0

    def evaluate_slos(self, metrics: dict[str, float], metric_date: date) -> list[SLOBreach]:
        """Compare computed metrics against SLO thresholds and return breaches."""
        breaches: list[SLOBreach] = []
        for kpi, value in metrics.items():
            defn = KPI_DEFINITIONS.get(kpi, {})
            slo_min = defn.get("slo_min")
            slo_max = defn.get("slo_max")
            if slo_min is not None and value < slo_min:
                breaches.append(SLOBreach(kpi, value, slo_min, "below_min", metric_date))
            if slo_max is not None and value > slo_max:
                breaches.append(SLOBreach(kpi, value, slo_max, "above_max", metric_date))
        if breaches:
            logger.warning("SLO breaches detected: %d", len(breaches))
        return breaches

    def persist(self, metrics: dict[str, float], metric_date: date, breaches: list[SLOBreach]) -> None:
        row = {
            "metric_date": metric_date,
            "etl_loaded_at": datetime.utcnow(),
            "slo_breaches": len(breaches),
            **metrics,
        }
        pd.DataFrame([row]).to_sql(
            "kpi_daily_metrics", self.engine, if_exists="append", index=False
        )
        if breaches:
            breach_df = pd.DataFrame([vars(b) for b in breaches])
            breach_df.to_sql("slo_breach_events", self.engine, if_exists="append", index=False)

    def run(self, metric_date: date | None = None) -> dict:
        metric_date = metric_date or (datetime.utcnow().date() - timedelta(days=1))
        start = datetime.utcnow()
        try:
            gmv = self.compute_gmv(metric_date)
            dau = self.compute_dau(metric_date)
            conversion = self.compute_conversion_rate(metric_date, dau)
            aov = self.compute_aov(metric_date, gmv)

            metrics = {
                "gmv_usd": gmv,
                "daily_active_users": float(dau),
                "conversion_rate_pct": conversion,
                "avg_order_value_usd": aov,
            }

            breaches = self.evaluate_slos(metrics, metric_date)
            self.persist(metrics, metric_date, breaches)

            duration = (datetime.utcnow() - start).total_seconds()
            logger.info("metrics_pipeline SUCCESS for %s in %.2fs", metric_date, duration)
            return {"status": "success", "metrics": metrics, "breaches": len(breaches), "duration_secs": duration}
        except Exception as exc:
            logger.error("metrics_pipeline failed: %s", exc, exc_info=True)
            raise
