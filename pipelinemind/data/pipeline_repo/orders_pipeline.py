"""
Orders incremental ETL pipeline.
Reads modified orders from the OLTP source, applies business transformations,
and merges into the warehouse orders_fact table using an upsert strategy.
Pipeline SLO: >= 99.5 % success rate, <= 5 min latency per run.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Optional

import pandas as pd
from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine

logger = logging.getLogger(__name__)

STATUS_MAP: dict[str, int] = {
    "pending": 0,
    "confirmed": 1,
    "shipped": 2,
    "delivered": 3,
    "cancelled": -1,
}

HIGH_VALUE_THRESHOLD_USD = 1_000.0


@dataclass
class PipelineResult:
    status: str
    rows_extracted: int
    rows_loaded: int
    duration_secs: float
    error: Optional[str] = None


class OrdersPipeline:
    """
    Incremental Orders ETL pipeline.

    Uses a MERGE (upsert) strategy rather than INSERT OVERWRITE to handle
    late-arriving order status updates without duplicate rows.  The watermark
    is stored in the pipeline_state table and advanced only on success.

    Args:
        source_conn: SQLAlchemy connection string for the OLTP source.
        target_conn: SQLAlchemy connection string for the warehouse.
        lookback_hours: Default look-back window when no watermark exists.
    """

    STAGING_TABLE = "stg_orders_tmp"
    FACT_TABLE = "orders_fact"

    def __init__(
        self,
        source_conn: str,
        target_conn: str,
        lookback_hours: int = 24,
    ) -> None:
        self.source_engine: Engine = create_engine(source_conn, pool_pre_ping=True)
        self.target_engine: Engine = create_engine(target_conn, pool_pre_ping=True)
        self.lookback_hours = lookback_hours

    # ------------------------------------------------------------------
    # Extract
    # ------------------------------------------------------------------

    def extract(self, watermark: datetime) -> pd.DataFrame:
        """Pull orders modified since *watermark* from the source OLTP."""
        query = text(
            """
            SELECT
                order_id,
                customer_id,
                product_id,
                order_status,
                total_amount,
                currency,
                shipping_address_id,
                created_at,
                updated_at
            FROM orders
            WHERE updated_at >= :watermark
            ORDER BY updated_at ASC
            """
        )
        with self.source_engine.connect() as conn:
            df = pd.read_sql(query, conn, params={"watermark": watermark})
        logger.info("Extracted %d orders since %s", len(df), watermark.isoformat())
        return df

    # ------------------------------------------------------------------
    # Transform
    # ------------------------------------------------------------------

    def transform(self, df: pd.DataFrame) -> pd.DataFrame:
        """Apply business rules, type coercions, and derived column logic."""
        if df.empty:
            return df

        df = df.copy()
        df["order_date"] = pd.to_datetime(df["created_at"]).dt.date
        df["order_month"] = pd.to_datetime(df["created_at"]).dt.to_period("M").astype(str)
        df["is_high_value"] = df["total_amount"] > HIGH_VALUE_THRESHOLD_USD
        df["status_code"] = df["order_status"].map(STATUS_MAP).fillna(-99).astype(int)
        df["total_amount"] = df["total_amount"].round(2)
        df["etl_loaded_at"] = datetime.utcnow()

        # Drop rows with missing mandatory keys
        before = len(df)
        df = df.dropna(subset=["order_id", "customer_id"])
        dropped = before - len(df)
        if dropped:
            logger.warning("Dropped %d rows with null primary keys", dropped)

        return df

    # ------------------------------------------------------------------
    # Load
    # ------------------------------------------------------------------

    def load(self, df: pd.DataFrame) -> int:
        """MERGE transformed records into the warehouse fact table."""
        if df.empty:
            return 0

        # Stage into a temporary table
        df.to_sql(
            self.STAGING_TABLE,
            self.target_engine,
            if_exists="replace",
            index=False,
            method="multi",
            chunksize=500,
        )

        merge_sql = text(
            f"""
            INSERT INTO {self.FACT_TABLE}
                SELECT * FROM {self.STAGING_TABLE}
            ON CONFLICT (order_id) DO UPDATE SET
                order_status     = EXCLUDED.order_status,
                status_code      = EXCLUDED.status_code,
                total_amount     = EXCLUDED.total_amount,
                is_high_value    = EXCLUDED.is_high_value,
                updated_at       = EXCLUDED.updated_at,
                etl_loaded_at    = EXCLUDED.etl_loaded_at
            """
        )
        with self.target_engine.begin() as conn:
            conn.execute(merge_sql)

        logger.info("Merged %d records into %s", len(df), self.FACT_TABLE)
        return len(df)

    # ------------------------------------------------------------------
    # Watermark management
    # ------------------------------------------------------------------

    def _get_watermark(self) -> datetime:
        with self.target_engine.connect() as conn:
            row = conn.execute(
                text("SELECT last_watermark FROM pipeline_state WHERE pipeline_id = 'orders'")
            ).fetchone()
        if row:
            return row[0]
        return datetime.utcnow() - timedelta(hours=self.lookback_hours)

    def _advance_watermark(self, new_watermark: datetime) -> None:
        with self.target_engine.begin() as conn:
            conn.execute(
                text(
                    """
                    INSERT INTO pipeline_state (pipeline_id, last_watermark)
                    VALUES ('orders', :ts)
                    ON CONFLICT (pipeline_id) DO UPDATE SET last_watermark = EXCLUDED.last_watermark
                    """
                ),
                {"ts": new_watermark},
            )

    # ------------------------------------------------------------------
    # Entrypoint
    # ------------------------------------------------------------------

    def run(self, watermark: Optional[datetime] = None) -> PipelineResult:
        """Execute the full extract → transform → load cycle."""
        start = datetime.utcnow()
        watermark = watermark or self._get_watermark()

        try:
            raw_df = self.extract(watermark)
            transformed_df = self.transform(raw_df)
            rows_loaded = self.load(transformed_df)
            self._advance_watermark(datetime.utcnow())

            duration = (datetime.utcnow() - start).total_seconds()
            logger.info("orders pipeline SUCCESS — %d rows in %.2fs", rows_loaded, duration)
            return PipelineResult(
                status="success",
                rows_extracted=len(raw_df),
                rows_loaded=rows_loaded,
                duration_secs=duration,
            )
        except Exception as exc:
            duration = (datetime.utcnow() - start).total_seconds()
            logger.error("orders pipeline FAILED after %.2fs: %s", duration, exc, exc_info=True)
            return PipelineResult(
                status="failed",
                rows_extracted=0,
                rows_loaded=0,
                duration_secs=duration,
                error=str(exc),
            )
