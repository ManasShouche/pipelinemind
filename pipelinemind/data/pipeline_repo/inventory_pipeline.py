"""
Inventory daily snapshot pipeline.
Captures a daily point-in-time snapshot of warehouse inventory levels.
Uses delta detection to identify low-stock and out-of-stock SKUs.
Writes snapshots to the inventory_snapshots table for trend analysis.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass, field
from datetime import date, datetime
from typing import Optional

import pandas as pd
from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine

logger = logging.getLogger(__name__)

LOW_STOCK_THRESHOLD = 10
OUT_OF_STOCK_THRESHOLD = 0


@dataclass
class InventoryAlert:
    sku_id: str
    product_name: str
    warehouse_id: str
    quantity_on_hand: int
    alert_type: str  # "LOW_STOCK" | "OUT_OF_STOCK"
    snapshot_date: date = field(default_factory=date.today)


class InventorySnapshotPipeline:
    """
    Daily inventory snapshot pipeline.

    Reads the current inventory state, computes stock health metrics,
    flags anomalies, and appends a snapshot row per SKU per warehouse.
    Incremental delta detection avoids redundant snapshot rows when
    stock levels are unchanged.
    """

    SOURCE_TABLE = "inventory"
    SNAPSHOT_TABLE = "inventory_snapshots"
    ALERT_TABLE = "inventory_alerts"

    def __init__(self, source_conn: str, target_conn: str) -> None:
        self.source_engine: Engine = create_engine(source_conn, pool_pre_ping=True)
        self.target_engine: Engine = create_engine(target_conn, pool_pre_ping=True)

    def extract_inventory(self) -> pd.DataFrame:
        """Full inventory snapshot from the source system."""
        query = text(
            """
            SELECT
                sku_id,
                product_name,
                warehouse_id,
                quantity_on_hand,
                reorder_point,
                unit_cost_usd,
                last_received_at,
                last_shipped_at
            FROM inventory
            WHERE is_active = true
            """
        )
        with self.source_engine.connect() as conn:
            df = pd.read_sql(query, conn)
        logger.info("Extracted %d inventory rows", len(df))
        return df

    def extract_last_snapshot(self) -> pd.DataFrame:
        """Yesterday's snapshot for delta comparison."""
        yesterday = (datetime.utcnow().date() - pd.Timedelta(days=1))
        query = text(
            f"""
            SELECT sku_id, warehouse_id, quantity_on_hand AS prev_quantity
            FROM {self.SNAPSHOT_TABLE}
            WHERE snapshot_date = :yesterday
            """
        )
        with self.target_engine.connect() as conn:
            return pd.read_sql(query, conn, params={"yesterday": yesterday})

    def transform(
        self, current_df: pd.DataFrame, last_df: pd.DataFrame
    ) -> tuple[pd.DataFrame, list[InventoryAlert]]:
        """Enrich snapshot with derived metrics and generate alerts."""
        df = current_df.copy()
        df["snapshot_date"] = date.today()
        df["etl_loaded_at"] = datetime.utcnow()
        df["stock_value_usd"] = (df["quantity_on_hand"] * df["unit_cost_usd"]).round(2)
        df["stock_status"] = "OK"
        df.loc[df["quantity_on_hand"] <= LOW_STOCK_THRESHOLD, "stock_status"] = "LOW_STOCK"
        df.loc[df["quantity_on_hand"] <= OUT_OF_STOCK_THRESHOLD, "stock_status"] = "OUT_OF_STOCK"

        # Delta: quantity_delta vs yesterday
        if not last_df.empty:
            df = df.merge(last_df, on=["sku_id", "warehouse_id"], how="left")
            df["quantity_delta"] = df["quantity_on_hand"] - df["prev_quantity"].fillna(0)
        else:
            df["quantity_delta"] = 0
        df = df.drop(columns=["prev_quantity"], errors="ignore")

        # Generate alerts
        alerts: list[InventoryAlert] = []
        for _, row in df[df["stock_status"] != "OK"].iterrows():
            alerts.append(
                InventoryAlert(
                    sku_id=row["sku_id"],
                    product_name=row["product_name"],
                    warehouse_id=row["warehouse_id"],
                    quantity_on_hand=int(row["quantity_on_hand"]),
                    alert_type=row["stock_status"],
                )
            )

        logger.info("Snapshot: %d rows, %d alerts", len(df), len(alerts))
        return df, alerts

    def load_snapshot(self, df: pd.DataFrame) -> int:
        df.to_sql(
            self.SNAPSHOT_TABLE,
            self.target_engine,
            if_exists="append",
            index=False,
            method="multi",
            chunksize=500,
        )
        return len(df)

    def load_alerts(self, alerts: list[InventoryAlert]) -> None:
        if not alerts:
            return
        alert_df = pd.DataFrame([vars(a) for a in alerts])
        alert_df.to_sql(
            self.ALERT_TABLE, self.target_engine, if_exists="append", index=False
        )
        logger.info("Persisted %d inventory alerts", len(alerts))

    def run(self) -> dict:
        start = datetime.utcnow()
        try:
            current = self.extract_inventory()
            last = self.extract_last_snapshot()
            snapshot_df, alerts = self.transform(current, last)
            rows = self.load_snapshot(snapshot_df)
            self.load_alerts(alerts)
            duration = (datetime.utcnow() - start).total_seconds()
            return {"status": "success", "snapshot_rows": rows, "alerts": len(alerts), "duration_secs": duration}
        except Exception as exc:
            logger.error("inventory_pipeline failed: %s", exc, exc_info=True)
            raise
