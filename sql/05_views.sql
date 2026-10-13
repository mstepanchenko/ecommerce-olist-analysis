-- 5.1 Представления для Power BI

-- v_monthly: заказы, выручка и средний чек по месяцам (запрос из 3.1)
CREATE OR REPLACE VIEW v_monthly AS
WITH pay AS (
    SELECT order_id, SUM(payment_value) AS order_payment
    FROM order_payments
    GROUP BY order_id
)
SELECT DATE_TRUNC('month', o.order_purchase_timestamp)::date AS month,
       COUNT(*)                         AS orders,
       ROUND(SUM(pay.order_payment), 0) AS revenue,
       ROUND(AVG(pay.order_payment), 2) AS aov
FROM orders o
JOIN pay ON pay.order_id = o.order_id
WHERE o.order_status = 'delivered'
  AND o.order_purchase_timestamp >= '2017-01-01'
  AND o.order_purchase_timestamp <  '2018-09-01'
GROUP BY 1;

-- v_cohort_retention: когортная таблица удержания (запрос из 3.3.2)
CREATE OR REPLACE VIEW v_cohort_retention AS
WITH orders_c AS (
    SELECT c.customer_unique_id,
           DATE_TRUNC('month', o.order_purchase_timestamp)::date AS order_month
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.order_status = 'delivered'
      AND o.order_purchase_timestamp >= '2017-01-01'
      AND o.order_purchase_timestamp <  '2018-09-01'
),
cohorts AS (
    SELECT customer_unique_id,
           order_month,
           MIN(order_month) OVER (PARTITION BY customer_unique_id) AS cohort_month
    FROM orders_c
),
cm AS (
    SELECT customer_unique_id,
           cohort_month,
           ((DATE_PART('year',  order_month) - DATE_PART('year',  cohort_month)) * 12
          + (DATE_PART('month', order_month) - DATE_PART('month', cohort_month)))::int AS month_number
    FROM cohorts
),
cohort_counts AS (
    SELECT cohort_month,
           COUNT(DISTINCT customer_unique_id) FILTER (WHERE month_number = 0)  AS size,
           COUNT(DISTINCT customer_unique_id) FILTER (WHERE month_number = 1)  AS m1,
           COUNT(DISTINCT customer_unique_id) FILTER (WHERE month_number = 2)  AS m2,
           COUNT(DISTINCT customer_unique_id) FILTER (WHERE month_number = 3)  AS m3,
           COUNT(DISTINCT customer_unique_id) FILTER (WHERE month_number = 6)  AS m6,
           COUNT(DISTINCT customer_unique_id) FILTER (WHERE month_number = 12) AS m12
    FROM cm
    GROUP BY cohort_month
)
SELECT cohort_month,
       size,
       CASE WHEN cohort_month + INTERVAL '1 month'   <= '2018-08-01' THEN ROUND(100.0 * m1  / size, 2) END AS m1_pct,
       CASE WHEN cohort_month + INTERVAL '2 months'  <= '2018-08-01' THEN ROUND(100.0 * m2  / size, 2) END AS m2_pct,
       CASE WHEN cohort_month + INTERVAL '3 months'  <= '2018-08-01' THEN ROUND(100.0 * m3  / size, 2) END AS m3_pct,
       CASE WHEN cohort_month + INTERVAL '6 months'  <= '2018-08-01' THEN ROUND(100.0 * m6  / size, 2) END AS m6_pct,
       CASE WHEN cohort_month + INTERVAL '12 months' <= '2018-08-01' THEN ROUND(100.0 * m12 / size, 2) END AS m12_pct
FROM cohort_counts;

-- v_delivery_score: оценка и доля плохих отзывов по корзинам опоздания (запрос из 3.4.2)
CREATE OR REPLACE VIEW v_delivery_score AS
WITH rev AS (
    SELECT order_id,
           AVG(review_score) AS score
    FROM order_reviews
    GROUP BY order_id
),
d AS (
    SELECT o.order_delivered_customer_date::date - o.order_estimated_delivery_date::date AS days_late,
           rev.score
    FROM orders o
    JOIN rev ON rev.order_id = o.order_id
    WHERE o.order_status = 'delivered'
      AND o.order_purchase_timestamp >= '2017-01-01'
      AND o.order_purchase_timestamp <  '2018-09-01'
      AND o.order_delivered_customer_date IS NOT NULL
      AND (o.order_delivered_carrier_date IS NULL
           OR o.order_delivered_customer_date >= o.order_delivered_carrier_date)
)
SELECT CASE WHEN days_late <= 0  THEN '0: вовремя'
            WHEN days_late <= 3  THEN '1: 1–3 дня'
            WHEN days_late <= 7  THEN '2: 4–7 дней'
            WHEN days_late <= 14 THEN '3: 8–14 дней'
            ELSE '4: 15+ дней' END                                     AS delay_bucket,
       COUNT(*)                                                        AS orders,
       ROUND(AVG(score), 2)                                            AS avg_score,
       ROUND(100.0 * COUNT(*) FILTER (WHERE score <= 2) / COUNT(*), 1) AS bad_review_pct
FROM d
GROUP BY delay_bucket;

-- v_category: выручка и «вес» доставки по категориям (запрос из 3.5)
CREATE OR REPLACE VIEW v_category AS
SELECT COALESCE(t.product_category_name_english, p.product_category_name, 'unknown')  AS category,
       COUNT(*)                                                                       AS items,
       ROUND(SUM(i.price), 0)                                           	      AS revenue,
       ROUND(100.0 * SUM(i.price) / SUM(SUM(i.price)) OVER (), 1)       	      AS revenue_pct,
       ROUND(100.0 * SUM(i.freight_value) / SUM(i.price), 1)            	      AS freight_to_price_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE i.freight_value > i.price) / COUNT(*), 1) AS freight_gt_price_pct
FROM order_items i
JOIN orders   o ON o.order_id   = i.order_id
JOIN products p ON p.product_id = i.product_id
LEFT JOIN product_category_name_translation t
       ON t.product_category_name = p.product_category_name
WHERE o.order_status = 'delivered'
  AND o.order_purchase_timestamp >= '2017-01-01'
  AND o.order_purchase_timestamp <  '2018-09-01'
GROUP BY category;

-- v_seller_funnel: воронка продавцов по каналу привлечения (запрос из 4.2)
CREATE OR REPLACE VIEW v_seller_funnel AS
SELECT COALESCE(m.origin, 'unknown')                              AS origin,
       COUNT(*)                                                   AS leads,
       COUNT(d.mql_id)                                            AS deals,
       ROUND(100.0 * COUNT(d.mql_id) / COUNT(*), 1)               AS conversion_pct,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)         AS leads_share_pct
FROM marketing_qualified_leads m
LEFT JOIN closed_deals d ON d.mql_id = m.mql_id
GROUP BY 1;