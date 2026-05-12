"""
Users SCD Type-2 dimension pipeline.
Tracks historical changes to user attributes using Slowly Changing Dimension
Type-2 (SCD2) logic: closes old records with an end date and inserts new ones.

PII notice: this pipeline processes user_id, email, and phone_number.
All PII columns are tagged in the DuckDB catalogue under pii_class = 'PII_HIGH'.
"""
from __future__ import annotations

import hashlib
import logging
from datetime import date, datetime
from typing import Optional

import pandas as pd
from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine

logger = logging.getLogger(__name__)

PII_COLUMNS = ["email", "phone_number", "full_name", "date_of_birth"]
SURROGATE_COLUMNS = ["email", "phone_number", "address_id", "subscription_tier"]


def _row_hash(row: pd.Series) -> str:
    """MD5 fingerprint of SCD-tracked columns to detect row-level changes."""
    payload = "|".join(str(row.get(c, "")) for c in sorted(SURROGATE_COLUMNS))
    return hashlib.md5(payload.encode()).hexdigest()


class UsersDimensionPipeline:
    """
    Implements SCD Type-2 for the users dimension table.

    On each run:
      1. Pull current snapshot of source users.
      2. Hash SCD-tracked columns to detect attribute changes.
      3. CLOSE expired records by setting is_current=false, valid_to=today.
      4. INSERT new records for changed or new users with is_current=true.

    The natural key is user_id; the surrogate key is user_sk (auto-increment).
    """

    SOURCE_TABLE = "users"
    DIM_TABLE = "dim_users"

    def __init__(self, source_conn: str, target_conn: str) -> None:
        self.source_engine: Engine = create_engine(source_conn, pool_pre_ping=True)
        self.target_engine: Engine = create_engine(target_conn, pool_pre_ping=True)

    # ------------------------------------------------------------------
    # Extract
    # ------------------------------------------------------------------

    def extract_source(self) -> pd.DataFrame:
        """Full snapshot of source users (SCD2 requires full comparison)."""
        query = text(
            """
            SELECT
                user_id,
                full_name,
                email,
                phone_number,
                date_of_birth,
                address_id,
                subscription_tier,
                created_at
            FROM users
            WHERE is_deleted = false
            """
        )
        with self.source_engine.connect() as conn:
            df = pd.read_sql(query, conn)
        df["row_hash"] = df.apply(_row_hash, axis=1)
        logger.info("Extracted %d source users", len(df))
        return df

    def extract_current_dim(self) -> pd.DataFrame:
        """Fetch currently active dimension records."""
        query = text(
            f"SELECT user_id, row_hash FROM {self.DIM_TABLE} WHERE is_current = true"
        )
        with self.target_engine.connect() as conn:
            return pd.read_sql(query, conn)

    # ------------------------------------------------------------------
    # Transform — SCD2 delta detection
    # ------------------------------------------------------------------

    def compute_deltas(
        self, source_df: pd.DataFrame, current_df: pd.DataFrame
    ) -> tuple[pd.DataFrame, pd.DataFrame]:
        """
        Returns (new_records, expired_user_ids).

        A record is NEW if:
          - user_id does not exist in the dimension (brand new user), OR
          - user_id exists but row_hash differs (attribute change).
        A record is EXPIRED if its user_id is in the dimension with a different hash.
        """
        merged = source_df.merge(
            current_df, on="user_id", how="left", suffixes=("_src", "_dim")
        )
        # Brand new users
        new_users = merged[merged["row_hash_dim"].isna()].copy()
        # Changed users
        changed_users = merged[
            merged["row_hash_dim"].notna()
            & (merged["row_hash_src"] != merged["row_hash_dim"])
        ].copy()

        new_records = pd.concat([new_users, changed_users], ignore_index=True)
        new_records = new_records.drop(columns=["row_hash_dim"], errors="ignore")
        new_records = new_records.rename(columns={"row_hash_src": "row_hash"})

        expired_ids = changed_users["user_id"].tolist()
        logger.info(
            "SCD2 delta: %d new, %d changed (%d to expire)",
            len(new_users),
            len(changed_users),
            len(expired_ids),
        )
        return new_records, expired_ids

    # ------------------------------------------------------------------
    # Load
    # ------------------------------------------------------------------

    def close_expired_records(self, expired_ids: list[str]) -> None:
        """Set is_current=false and valid_to=today for changed records."""
        if not expired_ids:
            return
        placeholders = ", ".join(f"'{uid}'" for uid in expired_ids)
        with self.target_engine.begin() as conn:
            conn.execute(
                text(
                    f"""
                    UPDATE {self.DIM_TABLE}
                    SET is_current = false,
                        valid_to   = :today
                    WHERE user_id IN ({placeholders})
                      AND is_current = true
                    """
                ),
                {"today": date.today()},
            )
        logger.info("Closed %d expired dimension records", len(expired_ids))

    def insert_new_records(self, new_df: pd.DataFrame) -> int:
        """Append fresh SCD2 records with is_current=true."""
        if new_df.empty:
            return 0
        new_df = new_df.copy()
        new_df["is_current"] = True
        new_df["valid_from"] = date.today()
        new_df["valid_to"] = date(9999, 12, 31)
        new_df["etl_loaded_at"] = datetime.utcnow()
        new_df.to_sql(
            self.DIM_TABLE, self.target_engine, if_exists="append", index=False, method="multi"
        )
        logger.info("Inserted %d new dimension records", len(new_df))
        return len(new_df)

    # ------------------------------------------------------------------
    # Entrypoint
    # ------------------------------------------------------------------

    def run(self) -> dict:
        start = datetime.utcnow()
        try:
            source_df = self.extract_source()
            current_df = self.extract_current_dim()
            new_records, expired_ids = self.compute_deltas(source_df, current_df)
            self.close_expired_records(expired_ids)
            rows_inserted = self.insert_new_records(new_records)
            duration = (datetime.utcnow() - start).total_seconds()
            return {
                "status": "success",
                "rows_inserted": rows_inserted,
                "records_expired": len(expired_ids),
                "duration_secs": duration,
            }
        except Exception as exc:
            logger.error("users_pipeline failed: %s", exc, exc_info=True)
            raise
