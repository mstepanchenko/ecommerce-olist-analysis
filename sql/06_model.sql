-- =========================================================
-- 06_model.sql — факт-таблица для модели «звезда» в Power BI
-- Гранулярность: 1 строка = 1 заказ
-- =========================================================

CREATE OR REPLACE VIEW v_order_facts AS
WITH pay AS (                       -- платежей у заказа бывает несколько
    SELECT order_id,
           SUM(payment_value) AS revenue
    FROM order_payments
    GROUP BY order_id
),
items AS (                          -- товаров у заказа бывает несколько
    SELECT order_id,
           COUNT(*) AS items
    FROM order_items
    GROUP BY order_id
),
rev AS (                            -- отзывов у заказа бывает несколько
    SELECT order_id,
           AVG(review_score) AS review_score
    FROM order_reviews
    GROUP BY order_id
)
SELECT
    o.order_id,
    c.customer_unique_id,
    c.customer_state,
    o.order_purchase_timestamp::DATE                       AS order_date,
    p.revenue,
    i.items,
    o.order_delivered_customer_date::DATE
      - o.order_estimated_delivery_date::DATE              AS delay_days,
    CASE
	WHEN o.order_delivered_customer_date IS NULL THEN NULL
        WHEN o.order_delivered_customer_date::DATE
           > o.order_estimated_delivery_date::DATE THEN 1
        ELSE 0
    END                                                    AS is_late,
    r.review_score
FROM orders o
JOIN customers c ON c.customer_id = o.customer_id
JOIN pay       p ON p.order_id    = o.order_id
JOIN items     i ON i.order_id    = o.order_id
LEFT JOIN rev   r ON r.order_id   = o.order_id
WHERE o.order_status = 'delivered'
  AND o.order_purchase_timestamp >= '2017-01-01'
  AND o.order_purchase_timestamp <  '2018-09-01';