-- PipelineMind DuckDB metadata store schema
-- Compatible with DuckDB 1.x (no FK enforcement by default)

CREATE TABLE IF NOT EXISTS catalogue_tables (
    table_id    VARCHAR PRIMARY KEY,
    table_name  VARCHAR NOT NULL,
    schema_name VARCHAR,
    description TEXT,
    domain      VARCHAR,
    pii_flag    BOOLEAN DEFAULT FALSE,
    tags        VARCHAR[],
    row_count   BIGINT  DEFAULT 0,
    created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS catalogue_columns (
    column_id    VARCHAR PRIMARY KEY,
    table_id     VARCHAR NOT NULL,
    column_name  VARCHAR NOT NULL,
    data_type    VARCHAR,
    pii_class    VARCHAR,
    nullable     BOOLEAN DEFAULT TRUE,
    description  TEXT,
    retention_days INTEGER
);

CREATE TABLE IF NOT EXISTS lineage_edges (
    edge_id       VARCHAR PRIMARY KEY,
    source_table  VARCHAR NOT NULL,
    source_column VARCHAR,
    target_table  VARCHAR NOT NULL,
    target_column VARCHAR,
    transformation VARCHAR,
    pipeline_id   VARCHAR,
    created_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS pipeline_runs (
    run_id        VARCHAR PRIMARY KEY,
    pipeline_id   VARCHAR NOT NULL,
    status        VARCHAR NOT NULL,
    start_time    TIMESTAMP,
    duration_secs DOUBLE,
    error_message TEXT,
    slo_met       BOOLEAN DEFAULT TRUE,
    created_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS slo_definitions (
    slo_id      VARCHAR PRIMARY KEY,
    pipeline_id VARCHAR NOT NULL,
    metric_name VARCHAR NOT NULL,
    target_value DOUBLE NOT NULL,
    comparison  VARCHAR NOT NULL,
    window_days INTEGER DEFAULT 7
);

CREATE TABLE IF NOT EXISTS schema_snapshots (
    snapshot_id VARCHAR PRIMARY KEY,
    table_id    VARCHAR,
    table_name  VARCHAR NOT NULL,
    columns_json TEXT NOT NULL,
    captured_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
