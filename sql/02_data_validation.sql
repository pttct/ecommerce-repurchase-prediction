SELECT
	count(*) as total_rows,
    COUNT(*) - COUNT(customer_id) AS missing_customer_id,
    COUNT(*) - COUNT(description) AS missing_description
FROM transactions_raw;

SELECT
	COUNT(*) as valid_lines,
    COUNT(DISTINCT customer_id) as unique_customers,
    COUNT(DISTINCT invoice) as unique_orders
FROM transactions_raw
WHERE
	customer_id IS NOT NULL and
    invoice NOT LIKE 'C%' and
    quantity > 0 and
    price > 0;

-- check if there are any duplicate invoice numbers
SELECT
    invoice,
    COUNT(DISTINCT source_year) AS year_count
FROM transactions_raw
GROUP BY invoice
HAVING COUNT(DISTINCT source_year) > 1
LIMIT 10;


SELECT
    source_year,
    COUNT(*) AS line_count,
    MIN(invoice_date) AS first_date,
    MAX(invoice_date) AS last_date,
    COUNT(DISTINCT customer_id) AS customer_count
FROM transactions_raw
WHERE invoice = '536365'
GROUP BY source_year;

SELECT
    source_year,
    invoice,
    stock_code,
    description,
    quantity,
    invoice_date,
    price,
    customer_id,
    country
FROM transactions_raw
WHERE invoice = '536365'
ORDER BY stock_code, source_year, row_id;

-- see how bad the duplicate issue is 
SELECT
    COUNT(*) AS overlapping_invoices
FROM (
    SELECT invoice
    FROM transactions_raw
    GROUP BY invoice
    HAVING COUNT(DISTINCT source_year) > 1
) AS overlapping;

-- see the time span of two sheets
SELECT
    source_year,
    MIN(invoice_date) AS first_date,
    MAX(invoice_date) AS last_date,
    COUNT(*) AS total_lines
FROM transactions_raw
GROUP BY source_year
ORDER BY source_year;



SELECT
    source_year,
    COUNT(*) AS overlapping_window_lines,
    COUNT(DISTINCT invoice) AS invoices_in_window
FROM transactions_raw
WHERE invoice_date >= '2010-12-01'
  AND invoice_date < '2010-12-10'
GROUP BY source_year;


SELECT COUNT(*) AS mismatched_records
FROM (
    SELECT
        invoice,
        stock_code,
        description,
        quantity,
        invoice_date,
        price,
        customer_id,
        country,
        SUM(CASE WHEN source_year = '2009-2010'
            THEN 1 ELSE 0 END) AS count_0910,
        SUM(CASE WHEN source_year = '2010-2011'
            THEN 1 ELSE 0 END) AS count_1011
    FROM transactions_raw
    WHERE invoice_date >= '2010-12-01'
      AND invoice_date < '2010-12-10'
    GROUP BY
        invoice, stock_code, description,
        quantity, invoice_date, price,
        customer_id, country
    HAVING count_0910 <> count_1011
) AS comparison;

SELECT 
	COUNT(*)
FROM transactions_raw
WHERE NOT(
	source_year = '2010-2011'
    AND invoice_date >= '2010-12-01'
    AND invoice_date < '2010-12-10'
);

USE ecommerce_repurchase;

CREATE VIEW transactions_deduplicated AS
SELECT *
FROM transactions_raw
WHERE NOT (
    source_year = '2010-2011'
    AND invoice_date >= '2010-12-01'
    AND invoice_date < '2010-12-10'
);


SELECT
    COUNT(*) AS total_rows,
    SUM(price < 0) AS negative_price_rows,
    SUM(price = 0) AS zero_price_rows,
    SUM(quantity = 0) AS zero_quantity_rows
FROM transactions_deduplicated;


SELECT
    invoice,
    stock_code,
    description,
    quantity,
    price,
    customer_id,
    invoice_date
FROM transactions_deduplicated
WHERE price < 0
ORDER BY price;
-- All five negative-price records were identified as bad-debt adjustments and excluded from the candidate valid-purchase dataset.

SELECT
    CASE
        WHEN quantity < 0 THEN 'Negative'
        WHEN quantity > 0 THEN 'Positive'
        ELSE 'Zero'
    END AS quantity_type,
    CASE
        WHEN customer_id IS NULL THEN 'Missing'
        ELSE 'Present'
    END AS customer_status,
    COUNT(*) AS line_count
FROM transactions_deduplicated
WHERE price = 0
GROUP BY quantity_type, customer_status
ORDER BY line_count DESC;

SELECT *
FROM transactions_deduplicated
WHERE
	price = 0
	AND quantity > 0
	AND customer_id IS NOT NULL
LIMIT 10;


WITH zero_price_check AS (
    SELECT
        z.invoice,
        z.customer_id,
        CASE
            WHEN EXISTS (
                SELECT 1
                FROM transactions_deduplicated AS p
                WHERE p.invoice = z.invoice
                  AND p.customer_id = z.customer_id
                  AND p.price > 0
                  AND p.quantity > 0
                  AND p.invoice NOT LIKE 'C%'
            ) THEN 'Yes'
            ELSE 'No'
        END AS has_paid_items
    FROM transactions_deduplicated AS z
    WHERE z.price = 0
      AND z.quantity > 0
      AND z.customer_id IS NOT NULL
)
SELECT
    has_paid_items,
    COUNT(*) AS line_count
FROM zero_price_check
GROUP BY has_paid_items;
EXPLAIN
SELECT *
FROM transactions_deduplicated
WHERE invoice = '489825'
  AND customer_id = 16126
  AND price > 0
  AND quantity > 0;
  
  
SELECT
    z.invoice,
    z.stock_code,
    z.description,
    z.quantity,
    z.price,
    z.customer_id,
    z.invoice_date
FROM transactions_deduplicated AS z
WHERE z.price = 0
  AND z.quantity > 0
  AND z.customer_id IS NOT NULL
  AND NOT EXISTS (
      SELECT 1
      FROM transactions_deduplicated AS p
      WHERE p.invoice = z.invoice
        AND p.customer_id = z.customer_id
        AND p.price > 0
        AND p.quantity > 0
        AND p.invoice NOT LIKE 'C%'
  );

SELECT
    COUNT(*) AS paid_lines,
    COUNT(DISTINCT customer_id) AS paying_customers,
    COUNT(DISTINCT invoice, customer_id) AS paid_orders,
    SUM(quantity * price) AS gross_sales
FROM transactions_deduplicated
WHERE customer_id IS NOT NULL
  AND invoice NOT LIKE 'C%'
  AND quantity > 0
  AND price > 0;

SELECT
    invoice,
    COUNT(DISTINCT customer_id) AS customer_count
FROM transactions_deduplicated
WHERE customer_id IS NOT NULL
  AND invoice NOT LIKE 'C%'
  AND quantity > 0
  AND price > 0
GROUP BY invoice
HAVING COUNT(DISTINCT customer_id) > 1
ORDER BY customer_count DESC;



WITH order_dates AS (
    SELECT
        invoice,
        COUNT(DISTINCT invoice_date) AS date_count,
        TIMESTAMPDIFF(
            SECOND,
            MIN(invoice_date),
            MAX(invoice_date)
        ) AS time_diff_seconds
    FROM transactions_deduplicated
    WHERE customer_id IS NOT NULL
      AND invoice NOT LIKE 'C%'
      AND quantity > 0
      AND price > 0
    GROUP BY invoice
)
SELECT
    COUNT(*) AS total_orders,
    SUM(date_count > 1) AS inconsistent_orders,
    MAX(date_count) AS max_distinct_dates,
    MAX(time_diff_seconds) / 60 AS max_diff_minutes,
    SUM(time_diff_seconds > 3600) AS over_one_hour
FROM order_dates;


CREATE VIEW paid_orders_candidate AS
SELECT
    invoice,
    customer_id,
    MIN(invoice_date) AS order_date,
    COUNT(*) AS paid_line_count,
    SUM(quantity) AS total_quantity,
    SUM(quantity * price) AS order_amount
FROM transactions_deduplicated
WHERE customer_id IS NOT NULL
  AND invoice NOT LIKE 'C%'
  AND quantity > 0
  AND price > 0
GROUP BY invoice, customer_id;

SELECT
    COUNT(*) AS total_orders,
    COUNT(DISTINCT invoice, customer_id) AS unique_orders,
    COUNT(DISTINCT customer_id) AS unique_customers,
    SUM(paid_line_count) AS total_paid_lines,
    SUM(order_amount) AS total_gross_sales,
    MIN(order_amount) AS min_order_amount,
    MAX(order_amount) AS max_order_amount
FROM paid_orders_candidate;
SELECT
    invoice,
    invoice_date,
    stock_code,
    description,
    quantity,
    price,
    quantity * price AS line_amount
FROM transactions_deduplicated
WHERE customer_id = 12346
  AND invoice_date >= '2011-01-18'
  AND invoice_date < '2011-01-20'
ORDER BY invoice_date;

SELECT
    COUNT(*) AS cancellation_lines,
    COUNT(DISTINCT invoice) AS cancellation_invoices,
    COUNT(DISTINCT customer_id) AS affected_customers,
    SUM(quantity * price) AS cancellation_amount
FROM transactions_deduplicated
WHERE invoice LIKE 'C%'
  AND quantity < 0
  AND price > 0
  AND customer_id IS NOT NULL;
  
  SELECT
    invoice,
    invoice_date,
    stock_code,
    description,
    quantity,
    price,
    quantity * price AS line_amount
FROM transactions_deduplicated
WHERE customer_id = 12346
ORDER BY invoice_date;

SELECT
    invoice,
    MIN(invoice_date) AS order_date,
    COUNT(*) AS line_count,
    SUM(quantity) AS total_quantity,
    SUM(quantity * price) AS invoice_amount
FROM transactions_deduplicated
WHERE customer_id = 12346
GROUP BY invoice
ORDER BY order_date;

SELECT
    stock_code,
    description,
    COUNT(*) AS line_count,
    COUNT(DISTINCT invoice) AS invoice_count,
    COUNT(DISTINCT customer_id) AS customer_count,
    SUM(quantity * price) AS total_amount
FROM transactions_deduplicated
WHERE stock_code = 'TEST001'
GROUP BY stock_code, description;


CREATE VIEW positive_purchase_lines AS
SELECT *
FROM transactions_deduplicated
WHERE customer_id IS NOT NULL
  AND invoice NOT LIKE 'C%'
  AND quantity > 0
  AND price > 0
  AND stock_code <> 'TEST001';

CREATE VIEW cancellation_lines AS
SELECT
    row_id,
    invoice AS cancellation_invoice,
    customer_id,
    stock_code,
    description,
    invoice_date AS cancellation_date,
    quantity,
    price,
    -quantity AS cancelled_quantity,
    -(quantity * price) AS cancellation_amount
FROM transactions_deduplicated
WHERE invoice LIKE 'C%'
  AND quantity < 0
  AND price > 0
  AND customer_id IS NOT NULL;
SELECT
    COUNT(*) AS cancellation_lines,
    SUM(cancellation_amount) AS total_cancellation_amount
FROM cancellation_lines;



SELECT
    c.cancellation_invoice,
    COUNT(*) AS candidate_matches,
    COUNT(DISTINCT p.invoice) AS candidate_orders
FROM positive_purchase_lines AS p
JOIN cancellation_lines AS c
    ON p.customer_id = c.customer_id
   AND p.stock_code = c.stock_code
   AND p.price = c.price
   AND p.quantity = c.cancelled_quantity
   AND p.invoice_date <= c.cancellation_date
WHERE c.cancellation_invoice = 'C581484'
GROUP BY c.cancellation_invoice;
CREATE INDEX idx_purchase_matching
ON transactions_raw (
    customer_id,
    stock_code,
    price,
    quantity,
    invoice_date
);
SHOW INDEX
FROM transactions_raw
WHERE Key_name = 'idx_purchase_matching';


WITH candidate_match_counts AS (
    SELECT
        c.row_id AS cancellation_row_id,
        COUNT(p.row_id) AS candidate_matches
    FROM cancellation_lines AS c
    LEFT JOIN positive_purchase_lines AS p
        ON p.customer_id = c.customer_id
       AND p.stock_code = c.stock_code
       AND p.price = c.price
       AND p.quantity = c.cancelled_quantity
       AND p.invoice_date <= c.cancellation_date
    GROUP BY c.row_id
)
SELECT
    CASE
        WHEN candidate_matches = 0 THEN 'No match'
        WHEN candidate_matches = 1 THEN 'Unique candidate'
        ELSE 'Ambiguous'
    END AS match_status,
    COUNT(*) AS cancellation_lines
FROM candidate_match_counts
GROUP BY match_status;

WITH candidate_pairs AS (
    SELECT
        c.row_id AS cancellation_row_id,
        p.row_id AS purchase_row_id
    FROM cancellation_lines AS c
    JOIN positive_purchase_lines AS p
        ON p.customer_id = c.customer_id
       AND p.stock_code = c.stock_code
       AND p.price = c.price
       AND p.quantity = c.cancelled_quantity
       AND p.invoice_date <= c.cancellation_date
),
unique_matches AS (
    SELECT
        cancellation_row_id,
        MIN(purchase_row_id) AS purchase_row_id
    FROM candidate_pairs
    GROUP BY cancellation_row_id
    HAVING COUNT(*) = 1
)
SELECT
    purchase_row_id,
    COUNT(*) AS cancellation_count
FROM unique_matches
GROUP BY purchase_row_id
HAVING COUNT(*) > 1
ORDER BY cancellation_count DESC
LIMIT 10;

WITH candidate_pairs AS (
    SELECT
        c.row_id AS cancellation_row_id,
        p.row_id AS purchase_row_id
    FROM cancellation_lines AS c
    JOIN positive_purchase_lines AS p
        ON p.customer_id = c.customer_id
       AND p.stock_code = c.stock_code
       AND p.price = c.price
       AND p.quantity = c.cancelled_quantity
       AND p.invoice_date <= c.cancellation_date
),
unique_matches AS (
    SELECT
        cancellation_row_id,
        MIN(purchase_row_id) AS purchase_row_id
    FROM candidate_pairs
    GROUP BY cancellation_row_id
    HAVING COUNT(*) = 1
),
conflicts AS (
    SELECT
        purchase_row_id,
        COUNT(*) AS cancellation_count
    FROM unique_matches
    GROUP BY purchase_row_id
    HAVING COUNT(*) > 1
)
SELECT
    COUNT(*) AS conflicting_purchase_lines,
    SUM(cancellation_count) AS involved_cancellation_lines,
    MAX(cancellation_count) AS max_conflict_count
FROM conflicts;

WITH candidate_pairs AS (
    SELECT
        c.row_id AS cancellation_row_id,
        p.row_id AS purchase_row_id
    FROM cancellation_lines AS c
    JOIN positive_purchase_lines AS p
        ON p.customer_id = c.customer_id
       AND p.stock_code = c.stock_code
       AND p.price = c.price
       AND p.quantity = c.cancelled_quantity
       AND p.invoice_date <= c.cancellation_date
),
match_counts AS (
    SELECT
        cancellation_row_id,
        purchase_row_id,
        COUNT(*) OVER (
            PARTITION BY cancellation_row_id
        ) AS purchase_candidates,
        COUNT(*) OVER (
            PARTITION BY purchase_row_id
        ) AS cancellation_candidates
    FROM candidate_pairs
)
SELECT
    COUNT(*) AS mutual_unique_matches
FROM match_counts
WHERE purchase_candidates = 1
  AND cancellation_candidates = 1;


CREATE VIEW mutual_unique_cancellations AS
WITH candidate_pairs AS (
    SELECT
        c.row_id AS cancellation_row_id,
        p.row_id AS purchase_row_id
    FROM cancellation_lines AS c
    JOIN positive_purchase_lines AS p
        ON p.customer_id = c.customer_id
       AND p.stock_code = c.stock_code
       AND p.price = c.price
       AND p.quantity = c.cancelled_quantity
       AND p.invoice_date <= c.cancellation_date
),
match_counts AS (
    SELECT
        cancellation_row_id,
        purchase_row_id,
        COUNT(*) OVER (
            PARTITION BY cancellation_row_id
        ) AS purchase_candidates,
        COUNT(*) OVER (
            PARTITION BY purchase_row_id
        ) AS cancellation_candidates
    FROM candidate_pairs
)
SELECT
    cancellation_row_id,
    purchase_row_id
FROM match_counts
WHERE purchase_candidates = 1
  AND cancellation_candidates = 1;
SELECT COUNT(*) AS matched_pairs
FROM mutual_unique_cancellations;


WITH order_match_stats AS (
    SELECT
        p.invoice,
        p.customer_id,
        COUNT(*) AS paid_lines,
        COUNT(m.purchase_row_id) AS matched_lines
    FROM positive_purchase_lines AS p
    LEFT JOIN mutual_unique_cancellations AS m
        ON p.row_id = m.purchase_row_id
    GROUP BY
        p.invoice,
        p.customer_id
)
SELECT
    COUNT(*) AS total_orders,
    SUM(matched_lines = 0) AS no_match_orders,
    SUM(
        matched_lines > 0
        AND matched_lines < paid_lines
    ) AS partially_matched_orders,
    SUM(matched_lines = paid_lines) AS fully_matched_orders
FROM order_match_stats;
SELECT
    p.invoice,
    COUNT(*) AS paid_lines,
    COUNT(m.purchase_row_id) AS matched_lines,
    CASE
        WHEN COUNT(m.purchase_row_id) = COUNT(*)
            THEN 'Fully matched'
        ELSE 'Not fully matched'
    END AS match_status
FROM positive_purchase_lines AS p
LEFT JOIN mutual_unique_cancellations AS m
    ON p.row_id = m.purchase_row_id
WHERE p.invoice IN ('581483', '541431')
GROUP BY p.invoice;


CREATE VIEW purchase_order_match_status AS
SELECT
    p.invoice,
    p.customer_id,
    MIN(p.invoice_date) AS order_date,
    COUNT(*) AS paid_lines,
    COUNT(m.purchase_row_id) AS matched_lines,
    SUM(p.quantity * p.price) AS gross_amount,
    CASE
        WHEN COUNT(m.purchase_row_id) = 0
            THEN 'No match'
        WHEN COUNT(m.purchase_row_id) = COUNT(*)
            THEN 'Fully matched'
        ELSE 'Partially matched'
    END AS match_status
FROM positive_purchase_lines AS p
LEFT JOIN mutual_unique_cancellations AS m
    ON p.row_id = m.purchase_row_id
GROUP BY
    p.invoice,
    p.customer_id;

WITH order_summary AS (
    SELECT
        invoice,
        customer_id,
        MIN(invoice_date) AS order_date,
        SUM(quantity * price) AS order_amount
    FROM positive_purchase_lines
    GROUP BY invoice, customer_id
)
SELECT
    customer_id,
    COUNT(*) AS order_count,
    MIN(order_date) AS first_order_date,
    MAX(order_date) AS last_order_date,
    SUM(order_amount) AS gross_spending
FROM order_summary
GROUP BY customer_id
ORDER BY order_count DESC
LIMIT 10;

WITH customer_order_counts AS (
    SELECT
        customer_id,
        COUNT(DISTINCT invoice) AS order_count
    FROM positive_purchase_lines
    GROUP BY customer_id
)
SELECT
    COUNT(*) AS total_customers,
    SUM(order_count = 1) AS one_time_customers,
    SUM(order_count >= 2) AS repeat_customers,
    ROUND(
        100.0 * SUM(order_count >= 2) / COUNT(*),
        2
    ) AS repeat_customer_pct,
    MAX(order_count) AS max_orders
FROM customer_order_counts;
EXPLAIN
SELECT
    customer_id,
    COUNT(DISTINCT invoice) AS order_count
FROM positive_purchase_lines
GROUP BY customer_id;


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
SELECT COUNT(*) AS total_orders
FROM order_summary;


WITH customer_order_counts AS (
    SELECT
        customer_id,
        COUNT(*) AS order_count
    FROM order_summary
    GROUP BY customer_id
)
SELECT
    COUNT(*) AS total_customers,
    SUM(order_count = 1) AS one_time_customers,
    SUM(order_count >= 2) AS repeat_customers,
    ROUND(
        100.0 * SUM(order_count >= 2) / COUNT(*),
        2
    ) AS repeat_customer_pct,
    MAX(order_count) AS max_orders
FROM customer_order_counts;


WITH customer_orders AS (
    SELECT
        customer_id,
        COUNT(*) AS order_count
    FROM order_summary
    GROUP BY customer_id
)
SELECT
    CASE
        WHEN order_count = 1 THEN '1 order'
        WHEN order_count BETWEEN 2 AND 3 THEN '2-3 orders'
        WHEN order_count BETWEEN 4 AND 9 THEN '4-9 orders'
        ELSE '10+ orders'
    END AS frequency_group,
    COUNT(*) AS customer_count
FROM customer_orders
GROUP BY frequency_group;
SELECT
    COUNT(DISTINCT customer_id) AS eligible_customers,
    COUNT(*) AS observed_orders
FROM order_summary
WHERE order_date >= '2010-12-01'
  AND order_date < '2011-06-01';
  
  

WITH observed_customers AS (
    SELECT DISTINCT customer_id
    FROM order_summary
    WHERE order_date >= '2010-12-01'
      AND order_date < '2011-06-01'
),
future_customers AS (
    SELECT DISTINCT customer_id
    FROM order_summary
    WHERE order_date >= '2011-06-01'
      AND order_date < '2011-09-01'
),
labels AS (
    SELECT
        o.customer_id,
        CASE
            WHEN f.customer_id IS NOT NULL THEN 1
            ELSE 0
        END AS repurchase
    FROM observed_customers AS o
    LEFT JOIN future_customers AS f
        ON o.customer_id = f.customer_id
)
SELECT
    COUNT(*) AS total_customers,
    SUM(repurchase = 1) AS positive_customers,
    SUM(repurchase = 0) AS negative_customers,
    ROUND(AVG(repurchase) * 100, 2) AS positive_rate_pct
FROM labels;


SELECT
    customer_id,
    DATEDIFF(
        '2011-06-01',
        MAX(order_date)
    ) AS recency_days,
    COUNT(*) AS frequency_6m,
    SUM(gross_amount) AS monetary_6m
FROM order_summary
WHERE order_date >= '2010-12-01'
  AND order_date < '2011-06-01'
GROUP BY customer_id
ORDER BY customer_id
LIMIT 10;


CREATE VIEW customer_snapshot_20110601_candidate AS

WITH rfm AS (
    SELECT
        customer_id,
        DATEDIFF(
            '2011-06-01',
            MAX(order_date)
        ) AS recency_days,
        COUNT(*) AS frequency_6m,
        SUM(gross_amount) AS monetary_6m
    FROM order_summary
    WHERE order_date >= '2010-12-01'
      AND order_date < '2011-06-01'
    GROUP BY customer_id
),
future_customers AS (
    SELECT DISTINCT customer_id
    FROM order_summary
    WHERE order_date >= '2011-06-01'
      AND order_date < '2011-09-01'
)
SELECT
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
    ON r.customer_id = f.customer_id;


SELECT
    COUNT(*) AS total_samples,
    COUNT(DISTINCT customer_id) AS unique_customers,
    SUM(repurchase) AS positive_samples,
    ROUND(AVG(repurchase) * 100, 2) AS positive_rate_pct
FROM customer_snapshot_20110601_candidate;


SELECT
    p.invoice AS purchase_invoice,
    p.customer_id,
    p.invoice_date AS purchase_date,
    c.cancellation_invoice,
    c.cancellation_date
FROM positive_purchase_lines AS p
JOIN cancellation_lines AS c
    ON p.customer_id = c.customer_id
   AND p.stock_code = c.stock_code
   AND p.price = c.price
   AND p.quantity = c.cancelled_quantity
   AND p.invoice_date <= c.cancellation_date
WHERE p.invoice_date >= '2010-12-01'
  AND p.invoice_date < '2011-06-01'
  AND c.cancellation_date >= '2011-06-01'
LIMIT 10;

SELECT
    COUNT(*) AS cross_cutoff_pairs,
    COUNT(DISTINCT p.invoice, p.customer_id) AS affected_orders,
    COUNT(DISTINCT p.customer_id) AS affected_customers
FROM mutual_unique_cancellations AS m
JOIN positive_purchase_lines AS p
    ON m.purchase_row_id = p.row_id
JOIN cancellation_lines AS c
    ON m.cancellation_row_id = c.row_id
WHERE p.invoice_date >= '2010-12-01'
  AND p.invoice_date < '2011-06-01'
  AND c.cancellation_date >= '2011-06-01';
  
  
WITH observed_customers AS (
    SELECT DISTINCT customer_id
    FROM order_summary
    WHERE order_date >= '2009-12-01'
      AND order_date < '2010-06-01'
),
future_customers AS (
    SELECT DISTINCT customer_id
    FROM order_summary
    WHERE order_date >= '2010-06-01'
      AND order_date < '2010-09-01'
)
SELECT
    COUNT(*) AS total_customers,
    SUM(f.customer_id IS NOT NULL) AS positive_customers,
    SUM(f.customer_id IS NULL) AS negative_customers,
    ROUND(
        100 * AVG(f.customer_id IS NOT NULL),
        2
    ) AS positive_rate_pct
FROM observed_customers AS o
LEFT JOIN future_customers AS f
    ON o.customer_id = f.customer_id;


WITH cutoffs AS (
    SELECT DATE('2010-06-01') AS cutoff_date
    UNION ALL SELECT DATE('2010-09-01')
    UNION ALL SELECT DATE('2010-12-01')
    UNION ALL SELECT DATE('2011-03-01')
    UNION ALL SELECT DATE('2011-06-01')
    UNION ALL SELECT DATE('2011-09-01')
),
observed AS (
    SELECT DISTINCT
        c.cutoff_date,
        o.customer_id
    FROM cutoffs AS c
    JOIN order_summary AS o
        ON o.order_date >= DATE_SUB(c.cutoff_date, INTERVAL 6 MONTH)
       AND o.order_date < c.cutoff_date
),
future AS (
    SELECT DISTINCT
        c.cutoff_date,
        o.customer_id
    FROM cutoffs AS c
    JOIN order_summary AS o
        ON o.order_date >= c.cutoff_date
       AND o.order_date < DATE_ADD(c.cutoff_date, INTERVAL 3 MONTH)
)
SELECT
    o.cutoff_date,
    COUNT(*) AS total_customers,
    SUM(f.customer_id IS NOT NULL) AS positive_customers,
    ROUND(
        AVG(f.customer_id IS NOT NULL) * 100,
        2
    ) AS positive_rate_pct
FROM observed AS o
LEFT JOIN future AS f
    ON o.cutoff_date = f.cutoff_date
   AND o.customer_id = f.customer_id
GROUP BY o.cutoff_date
ORDER BY o.cutoff_date;


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
SELECT
    cutoff_date,
    COUNT(*) AS total_samples,
    COUNT(DISTINCT customer_id) AS unique_customers,
    SUM(repurchase) AS positive_samples,
    ROUND(AVG(repurchase) * 100, 2) AS positive_rate_pct
FROM customer_snapshots_candidate
GROUP BY cutoff_date
ORDER BY cutoff_date;
