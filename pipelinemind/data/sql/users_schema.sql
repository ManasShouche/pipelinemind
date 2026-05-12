-- ============================================================================
-- Users domain schema — SCD Type-2 dimension
-- PII notice: email, phone_number, date_of_birth are PII_HIGH
-- ============================================================================

CREATE TABLE IF NOT EXISTS users (
    user_id           VARCHAR(36)   NOT NULL PRIMARY KEY,
    full_name         VARCHAR(200),                       -- PII_MEDIUM
    email             VARCHAR(320)  NOT NULL UNIQUE,      -- PII_HIGH
    phone_number      VARCHAR(20),                        -- PII_HIGH
    date_of_birth     DATE,                               -- PII_HIGH
    address_id        VARCHAR(36),
    subscription_tier VARCHAR(20)   DEFAULT 'free'
                        CHECK (subscription_tier IN ('free','basic','premium','enterprise')),
    is_deleted        BOOLEAN       DEFAULT FALSE,
    created_at        TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at        TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- SCD Type-2 dimension table (target of users_pipeline)
CREATE TABLE IF NOT EXISTS dim_users (
    user_sk           SERIAL        PRIMARY KEY,          -- surrogate key
    user_id           VARCHAR(36)   NOT NULL,             -- natural key
    full_name         VARCHAR(200),
    email             VARCHAR(320),
    phone_number      VARCHAR(20),
    date_of_birth     DATE,
    address_id        VARCHAR(36),
    subscription_tier VARCHAR(20),
    row_hash          VARCHAR(32)   NOT NULL,
    is_current        BOOLEAN       NOT NULL DEFAULT TRUE,
    valid_from        DATE          NOT NULL,
    valid_to          DATE          NOT NULL DEFAULT '9999-12-31',
    etl_loaded_at     TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_dim_users_natural   ON dim_users (user_id, is_current);
CREATE INDEX IF NOT EXISTS idx_dim_users_valid_from ON dim_users (valid_from);
