"""
Sessions streaming window aggregation pipeline.
Processes raw clickstream events and aggregates them into user session metrics
using a 30-minute inactivity timeout to define session boundaries.
Outputs to the sessions_agg table consumed by the BI layer.
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta
from typing import Iterator

import pandas as pd
from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine

logger = logging.getLogger(__name__)

SESSION_TIMEOUT_MINUTES = 30
WINDOW_HOURS = 2  # process events from the last N hours


def _assign_session_ids(events: pd.DataFrame) -> pd.DataFrame:
    """
    Assign session IDs using a 30-minute inactivity gap rule.

    Within each user partition, events are ordered by event_timestamp.
    A new session starts whenever the gap to the previous event exceeds
    SESSION_TIMEOUT_MINUTES.  The session_id is a composite of user_id
    and the session start timestamp.
    """
    events = events.sort_values(["user_id", "event_timestamp"]).copy()
    events["prev_ts"] = events.groupby("user_id")["event_timestamp"].shift(1)
    events["gap_minutes"] = (
        events["event_timestamp"] - events["prev_ts"]
    ).dt.total_seconds() / 60

    events["is_new_session"] = (
        events["prev_ts"].isna()
        | (events["gap_minutes"] > SESSION_TIMEOUT_MINUTES)
    )
    events["session_seq"] = events.groupby("user_id")["is_new_session"].cumsum()
    events["session_id"] = (
        events["user_id"].astype(str)
        + "_"
        + events["session_seq"].astype(str)
    )
    return events.drop(columns=["prev_ts", "gap_minutes", "is_new_session", "session_seq"])


class SessionAggregationPipeline:
    """
    Micro-batch session aggregation over a sliding time window.

    Reads raw clickstream events, assigns session boundaries,
    and produces per-session aggregate metrics.
    """

    EVENTS_TABLE = "clickstream_events"
    OUTPUT_TABLE = "sessions_agg"

    def __init__(self, source_conn: str, target_conn: str) -> None:
        self.source_engine: Engine = create_engine(source_conn, pool_pre_ping=True)
        self.target_engine: Engine = create_engine(target_conn, pool_pre_ping=True)

    def extract_events(self, watermark: datetime) -> pd.DataFrame:
        """Extract raw clickstream events within the processing window."""
        query = text(
            f"""
            SELECT
                event_id,
                user_id,
                session_hint_id,
                event_type,
                page_url,
                referrer_url,
                device_type,
                geo_country,
                event_timestamp
            FROM {self.EVENTS_TABLE}
            WHERE event_timestamp >= :watermark
              AND event_timestamp <  :now
            ORDER BY user_id, event_timestamp
            """
        )
        with self.source_engine.connect() as conn:
            df = pd.read_sql(
                query, conn,
                params={"watermark": watermark, "now": datetime.utcnow()},
                parse_dates=["event_timestamp"],
            )
        logger.info("Extracted %d clickstream events", len(df))
        return df

    def transform(self, events: pd.DataFrame) -> pd.DataFrame:
        """Assign sessions and aggregate to session-level metrics."""
        if events.empty:
            return pd.DataFrame()

        events = _assign_session_ids(events)

        agg = (
            events.groupby("session_id")
            .agg(
                user_id=("user_id", "first"),
                session_start=("event_timestamp", "min"),
                session_end=("event_timestamp", "max"),
                total_events=("event_id", "count"),
                unique_pages=("page_url", "nunique"),
                device_type=("device_type", "first"),
                geo_country=("geo_country", "first"),
                has_referrer=("referrer_url", lambda x: x.notna().any()),
            )
            .reset_index()
        )

        agg["duration_seconds"] = (
            agg["session_end"] - agg["session_start"]
        ).dt.total_seconds().astype(int)
        agg["is_bounce"] = (agg["total_events"] == 1) & (agg["duration_seconds"] < 10)
        agg["etl_loaded_at"] = datetime.utcnow()

        logger.info("Aggregated %d sessions from %d events", len(agg), len(events))
        return agg

    def load(self, sessions: pd.DataFrame) -> int:
        if sessions.empty:
            return 0
        sessions.to_sql(
            self.OUTPUT_TABLE,
            self.target_engine,
            if_exists="append",
            index=False,
            method="multi",
            chunksize=1000,
        )
        return len(sessions)

    def run(self) -> dict:
        start = datetime.utcnow()
        watermark = start - timedelta(hours=WINDOW_HOURS)
        try:
            events = self.extract_events(watermark)
            sessions = self.transform(events)
            rows = self.load(sessions)
            duration = (datetime.utcnow() - start).total_seconds()
            return {"status": "success", "sessions": rows, "events": len(events), "duration_secs": duration}
        except Exception as exc:
            logger.error("sessions_pipeline failed: %s", exc, exc_info=True)
            raise
