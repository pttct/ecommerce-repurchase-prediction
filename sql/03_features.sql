-- Behavioral features for E-commerce Repurchase Prediction (V1 + V2).
-- MySQL 8.3. Run after 02_build_dataset.sql.
-- This script drops and recreates the derived feature tables, but preserves
-- the validated feature logic from the original 03_features.sql.
-- WARNING: DO NOT run on the working DB until a rebuild is intended.
-- 6 calendar MONTHS != 180 DAYS. The V2 previous-90-day trend uses
-- a 180-day boundary while the underlying base_orders uses 6 calendar months.

USE ecommerce_repurchase;

-- Drop both materialized feature tables before rebuilding them.
DROP TABLE IF EXISTS snapshot_behavioral_features_v2;
DROP TABLE IF EXISTS snapshot_behavioral_features;

-- === V1 behavioral features (4 extras, plus 3 RFM fields elsewhere) ===
CREATE TABLE snapshot_behavioral_features AS

WITH base_orders AS (
    SELECT
        s.cutoff_date,
        s.customer_id,
        o.invoice,
        o.order_date,
        o.gross_amount
    FROM customer_snapshots_candidate s
    JOIN order_summary o
        ON s.customer_id = o.customer_id
        AND o.order_date >= DATE_SUB(
            s.cutoff_date, INTERVAL 6 MONTH
        )
        AND o.order_date < s.cutoff_date
),

order_features AS (
    SELECT
        cutoff_date,
        customer_id,

        COUNT(DISTINCT CASE
            WHEN order_date >= DATE_SUB(
                cutoff_date, INTERVAL 30 DAY
            )
            THEN invoice
        END) AS orders_last_30d,

        COUNT(DISTINCT CASE
            WHEN order_date >= DATE_SUB(
                cutoff_date, INTERVAL 90 DAY
            )
            THEN invoice
        END) AS orders_last_90d,

        ROUND(AVG(gross_amount), 2)
            AS avg_order_value_6m

    FROM base_orders
    GROUP BY cutoff_date, customer_id
),

product_features AS (
    SELECT
        b.cutoff_date,
        b.customer_id,

        COUNT(DISTINCT p.stock_code)
            AS unique_products_6m

    FROM base_orders b
    JOIN positive_purchase_lines p
        ON b.invoice = p.invoice
        AND b.customer_id = p.customer_id

    GROUP BY b.cutoff_date, b.customer_id
)

SELECT
    s.cutoff_date,
    s.customer_id,

    COALESCE(o.orders_last_30d, 0)
        AS orders_last_30d,

    COALESCE(o.orders_last_90d, 0)
        AS orders_last_90d,

    o.avg_order_value_6m,

    COALESCE(p.unique_products_6m, 0)
        AS unique_products_6m

FROM customer_snapshots_candidate s

LEFT JOIN order_features o
    ON s.cutoff_date = o.cutoff_date
    AND s.customer_id = o.customer_id

LEFT JOIN product_features p
    ON s.cutoff_date = p.cutoff_date
    AND s.customer_id = p.customer_id;
SELECT
    COUNT(*) AS total_rows,

    COUNT(DISTINCT cutoff_date, customer_id)
        AS unique_snapshots,

    SUM(orders_last_30d > orders_last_90d)
        AS invalid_order_counts,

    SUM(unique_products_6m = 0)
        AS zero_product_rows,

    SUM(avg_order_value_6m IS NULL)
        AS missing_aov

FROM snapshot_behavioral_features;




-- === V2 behavioral features (6 additional features) ===
CREATE TABLE snapshot_behavioral_features_v2 AS
WITH base_orders AS (
    SELECT
        s.customer_id,
        s.cutoff_date,
        o.invoice,
        o.order_date
    FROM customer_snapshots_candidate s
    JOIN order_summary o
        ON s.customer_id = o.customer_id
        AND o.order_date >= DATE_SUB(
            s.cutoff_date, INTERVAL 6 MONTH
        )
        AND o.order_date < s.cutoff_date
),

ordered AS (
    SELECT
        *,
        TIMESTAMPDIFF(
            SECOND,
            LAG(order_date) OVER (
                PARTITION BY customer_id, cutoff_date
                ORDER BY order_date, invoice
            ),
            order_date
        ) / 86400.0 AS gap_days
    FROM base_orders
),

aggregated AS (
    SELECT
        customer_id,
        cutoff_date,

        COUNT(DISTINCT DATE_FORMAT(
            order_date, '%Y-%m'
        )) AS active_months_6m,

        AVG(gap_days) AS avg_gap,
        STDDEV_POP(gap_days) AS std_gap,

        COUNT(*) AS orders_6m_check,

        SUM(
            order_date >= DATE_SUB(
                cutoff_date, INTERVAL 90 DAY
            )
        ) AS recent_90,

        SUM(
            order_date >= DATE_SUB(
                cutoff_date, INTERVAL 180 DAY
            )
            AND order_date < DATE_SUB(
                cutoff_date, INTERVAL 90 DAY
            )
        ) AS previous_90

    FROM ordered
    GROUP BY customer_id, cutoff_date
)

SELECT
    s.customer_id,
    s.cutoff_date,

    COALESCE(a.active_months_6m, 0)
        AS active_months_6m,

    COALESCE(a.avg_gap, 0)
        AS avg_days_between_orders,

    COALESCE(a.std_gap, 0)
        AS std_days_between_orders,

    CASE
        WHEN a.orders_6m_check >= 2 THEN 1
        ELSE 0
    END AS has_interorder_gap,

    COALESCE(a.previous_90, 0)
        AS orders_prev_90d,

    COALESCE(a.recent_90, 0)
        - COALESCE(a.previous_90, 0)
        AS order_change_90d,

    COALESCE(a.recent_90, 0)
        AS recent_90_check

FROM customer_snapshots_candidate s

LEFT JOIN aggregated a
    ON s.customer_id = a.customer_id
    AND s.cutoff_date = a.cutoff_date;


SELECT
    COUNT(*) AS total_rows,

    COUNT(DISTINCT
        v2.customer_id,
        v2.cutoff_date
    ) AS unique_snapshots,

    SUM(
        v2.recent_90_check <> v1.orders_last_90d
    ) AS inconsistent_90d,

    SUM(
        v2.active_months_6m = 0
    ) AS zero_active_months,

    SUM(
        v2.avg_days_between_orders < 0
        OR v2.std_days_between_orders < 0
    ) AS invalid_intervals,

    SUM(
        v2.has_interorder_gap = 0
        AND (
            v2.avg_days_between_orders <> 0
            OR v2.std_days_between_orders <> 0
        )
    ) AS invalid_gap_flags

FROM snapshot_behavioral_features_v2 v2

JOIN snapshot_behavioral_features v1
    ON v2.customer_id = v1.customer_id
    AND v2.cutoff_date = v1.cutoff_date;
