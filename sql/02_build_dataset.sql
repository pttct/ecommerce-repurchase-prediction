-- Build dataset objects for E-commerce Repurchase Prediction.
-- Source: existing verified statements in 02_data_validation.sql.
-- MySQL 8.3, run only AFTER transactions_raw has been populated.
-- WARNING: This rebuilds derived tables. Do NOT run on the working database
--          until the full reproduction workflow is ready for validation.
-- The original 02_data_validation.sql remains an exploratory audit notebook.

USE ecommerce_repurchase;

-- === Cross-sheet overlap removal ===
CREATE OR REPLACE VIEW transactions_deduplicated AS
SELECT *
FROM transactions_raw
WHERE NOT (
    source_year = '2010-2011'
    AND invoice_date >= '2010-12-01'
    AND invoice_date < '2010-12-10'
);

-- === Eligible positive purchase lines ===
CREATE OR REPLACE VIEW positive_purchase_lines AS
SELECT *
FROM transactions_deduplicated
WHERE customer_id IS NOT NULL
  AND invoice NOT LIKE 'C%'
  AND quantity > 0
  AND price > 0
  AND stock_code <> 'TEST001';

-- === Order-level aggregation ===
-- Rebuild dependent derived tables in dependency-safe order.
DROP TABLE IF EXISTS customer_snapshots_candidate;
DROP TABLE IF EXISTS order_summary;

CREATE TABLE order_summary AS
SELECT
    invoice,
    customer_id,
    MIN(invoice_date) AS order_date,
    COUNT(*) AS paid_line_count,
    SUM(quantity) AS total_quantity,
    SUM(quantity * price) AS gross_amount
FROM positive_purchase_lines
GROUP BY invoice, customer_id;

-- Recreate the useful lookup index on the newly materialized table.
-- This is safe on repeated full builds because order_summary is dropped above.
CREATE INDEX idx_customer_order_date
ON order_summary (customer_id, order_date);

-- === Six historical customer snapshots + labels ===
CREATE TABLE customer_snapshots_candidate AS
WITH cutoffs AS (
    SELECT DATE('2010-06-01') AS cutoff_date
    UNION ALL SELECT DATE('2010-09-01')
    UNION ALL SELECT DATE('2010-12-01')
    UNION ALL SELECT DATE('2011-03-01')
    UNION ALL SELECT DATE('2011-06-01')
    UNION ALL SELECT DATE('2011-09-01')
),
rfm AS (
    SELECT
        c.cutoff_date,
        o.customer_id,
        DATEDIFF(
            c.cutoff_date,
            MAX(o.order_date)
        ) AS recency_days,
        COUNT(*) AS frequency_6m,
        SUM(o.gross_amount) AS monetary_6m
    FROM cutoffs AS c
    JOIN order_summary AS o
        ON o.order_date >= DATE_SUB(
            c.cutoff_date, INTERVAL 6 MONTH
        )
       AND o.order_date < c.cutoff_date
    GROUP BY c.cutoff_date, o.customer_id
),
future_customers AS (
    SELECT DISTINCT
        c.cutoff_date,
        o.customer_id
    FROM cutoffs AS c
    JOIN order_summary AS o
        ON o.order_date >= c.cutoff_date
       AND o.order_date < DATE_ADD(
           c.cutoff_date, INTERVAL 3 MONTH
       )
)
SELECT
    r.cutoff_date,
    r.customer_id,
    r.recency_days,
    r.frequency_6m,
    r.monetary_6m,
    CASE
        WHEN f.customer_id IS NOT NULL THEN 1
        ELSE 0
    END AS repurchase
FROM rfm AS r
LEFT JOIN future_customers AS f
    ON r.cutoff_date = f.cutoff_date
   AND r.customer_id = f.customer_id;

-- Sanity checks against Stage 02 observed results, not hard-coded data creation.
SELECT COUNT(*) AS deduplicated_rows FROM transactions_deduplicated;  -- expected: 1,044,848
SELECT COUNT(*) AS order_rows FROM order_summary;                     -- expected: 36,960
SELECT COUNT(*) AS snapshot_rows FROM customer_snapshots_candidate;    -- expected: 17,957
SELECT COUNT(DISTINCT cutoff_date, customer_id) AS unique_snapshot_keys
FROM customer_snapshots_candidate;                                   -- expected: 17,957
