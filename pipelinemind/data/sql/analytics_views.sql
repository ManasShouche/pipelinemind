-- ============================================================================
-- Analytical layer views consumed by BI dashboards and ML feature store
-- These views depend on: orders_fact, dim_users, sessions_agg, inventory_snapshots
-- ============================================================================

-- Revenue by subscription tier (joins orders_fact -> dim_users SCD2)
CREATE OR REPLACE VIEW vw_revenue_by_tier AS
SELECT
    u.subscription_tier,
    DATE_TRUNC('month', o.order_date)      AS month,
    COUNT(DISTINCT o.order_id)             AS order_count,
    SUM(o.total_amount)                    AS gmv_usd,
    AVG(o.total_amount)                    AS avg_order_value,
    COUNT(DISTINCT o.customer_id)          AS unique_customers
FROM orders_fact o
JOIN dim_users u
    ON o.customer_id = u.user_id
   AND u.is_current = TRUE
WHERE o.status_code >= 1
GROUP BY 1, 2;

-- Daily funnel: sessions -> orders conversion
CREATE OR REPLACE VIEW vw_daily_funnel AS
WITH daily_sessions AS (
    SELECT
        DATE(session_start)      AS metric_date,
        COUNT(*)                 AS total_sessions,
        COUNT(DISTINCT user_id)  AS unique_users,
        SUM(CASE WHEN is_bounce THEN 1 ELSE 0 END) AS bounced_sessions
    FROM sessions_agg
    GROUP BY 1
),
daily_orders AS (
    SELECT
        order_date              AS metric_date,
        COUNT(*)                AS total_orders,
        SUM(total_amount)       AS gmv_usd
    FROM orders_fact
    WHERE status_code >= 1
    GROUP BY 1
)
SELECT
    s.metric_date,
    s.total_sessions,
    s.unique_users,
    s.bounced_sessions,
    ROUND(s.bounced_sessions * 100.0 / NULLIF(s.total_sessions, 0), 2) AS bounce_rate_pct,
    o.total_orders,
    o.gmv_usd,
    ROUND(o.total_orders * 100.0 / NULLIF(s.unique_users, 0), 4)       AS conversion_rate_pct
FROM daily_sessions s
LEFT JOIN daily_orders o USING (metric_date)
ORDER BY s.metric_date DESC;

-- Inventory health dashboard
CREATE OR REPLACE VIEW vw_inventory_health AS
SELECT
    snapshot_date,
    warehouse_id,
    COUNT(*)                                      AS total_skus,
    SUM(CASE WHEN stock_status = 'OK'          THEN 1 ELSE 0 END) AS healthy_skus,
    SUM(CASE WHEN stock_status = 'LOW_STOCK'   THEN 1 ELSE 0 END) AS low_stock_skus,
    SUM(CASE WHEN stock_status = 'OUT_OF_STOCK' THEN 1 ELSE 0 END) AS oos_skus,
    SUM(stock_value_usd)                          AS total_stock_value_usd
FROM inventory_snapshots
GROUP BY 1, 2
ORDER BY 1 DESC, 2;
