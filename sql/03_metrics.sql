-- 3.1 Выручка, заказы и средний чек (AOV) по месяцам
WITH pay AS (
    SELECT order_id,
           SUM(payment_value) AS order_payment
    FROM order_payments
    GROUP BY order_id
)
SELECT DATE_TRUNC('month', o.order_purchase_timestamp)::date AS month,
       COUNT(*)                          AS orders,
       ROUND(SUM(pay.order_payment), 0)  AS revenue,
       ROUND(AVG(pay.order_payment), 2)  AS aov
FROM orders o
JOIN pay ON pay.order_id = o.order_id
WHERE o.order_status = 'delivered'
  AND o.order_purchase_timestamp >= '2017-01-01'
  AND o.order_purchase_timestamp <  '2018-09-01'
GROUP BY month
ORDER BY month;

-- Вывод 3.1: рост выручки — за счёт числа заказов; AOV стабилен (146–170 BRL).
-- Пик — ноябрь 2017 (Black Friday): 7 289 заказов, 148 BRL выручки.

-- 3.2 Распределение покупателей по числу заказов
WITH cust_orders AS (
        SELECT c.customer_unique_id,
           COUNT(*) AS orders
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.order_status = 'delivered'
    GROUP BY c.customer_unique_id
)
SELECT orders,
       COUNT(*) AS customers,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM cust_orders
GROUP BY orders
ORDER BY orders;

-- Вывод 3.2: 93 358 покупателей, 97% купили один раз, повторно — 2 801 (3,0%).
-- Магазин живёт за счёт новых клиентов → retention — главная зона роста.