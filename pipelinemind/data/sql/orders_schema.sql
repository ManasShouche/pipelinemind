-- ============================================================================
-- Orders domain schema
-- Source-of-truth DDL for the orders pipeline
-- ============================================================================

CREATE TABLE IF NOT EXISTS orders (
    order_id           VARCHAR(36)    NOT NULL PRIMARY KEY,
    customer_id        VARCHAR(36)    NOT NULL,
    product_id         VARCHAR(36)    NOT NULL,
    order_status       VARCHAR(20)    NOT NULL CHECK (order_status IN
                         ('pending','confirmed','shipped','delivered','cancelled')),
    total_amount       NUMERIC(12,2)  NOT NULL CHECK (total_amount >= 0),
    currency           CHAR(3)        NOT NULL DEFAULT 'USD',
    shipping_address_id VARCHAR(36),
    created_at         TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at         TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_orders_customer  ON orders (customer_id);
CREATE INDEX IF NOT EXISTS idx_orders_updated   ON orders (updated_at);
CREATE INDEX IF NOT EXISTS idx_orders_status    ON orders (order_status);

-- Warehouse fact table (target of the orders ETL pipeline)
CREATE TABLE IF NOT EXISTS orders_fact (
    order_id            VARCHAR(36)   NOT NULL PRIMARY KEY,
    customer_id         VARCHAR(36)   NOT NULL,
    product_id          VARCHAR(36),
    order_status        VARCHAR(20),
    status_code         SMALLINT,
    total_amount        NUMERIC(12,2),
    currency            CHAR(3),
    is_high_value       BOOLEAN       DEFAULT FALSE,
    order_date          DATE,
    order_month         VARCHAR(7),
    shipping_address_id VARCHAR(36),
    created_at          TIMESTAMP,
    updated_at          TIMESTAMP,
    etl_loaded_at       TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS pipeline_state (
    pipeline_id     VARCHAR(64)  NOT NULL PRIMARY KEY,
    last_watermark  TIMESTAMP    NOT NULL
);

-- Staging table (transient; recreated each run)
CREATE TABLE IF NOT EXISTS stg_orders_tmp (LIKE orders_fact);
