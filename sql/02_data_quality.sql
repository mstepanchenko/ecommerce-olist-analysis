-- 2.1.1 Период данных
SELECT MIN(order_purchase_timestamp) AS first_order,
       MAX(order_purchase_timestamp) AS last_order,
       COUNT(*)                      AS orders
FROM orders;

-- 2.1.2 Распределение заказов по статусам
SELECT order_status,
       COUNT(*) AS orders,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM orders
GROUP BY order_status
ORDER BY orders DESC;

-- 2.2 Заказы по месяцам: ищем неполные месяцы по краям
SELECT DATE_TRUNC('month', order_purchase_timestamp)::date AS month,
       COUNT(*)                                          AS orders,
       COUNT(*) FILTER (WHERE order_status = 'delivered')      AS delivered
FROM orders
GROUP BY month
ORDER BY month;

-- Вывод 2.2: период анализа — 2017-01-01 … 2018-08-31 (20 полных месяцев).
-- 2016 — запуск (единичные заказы, ноябрь пустой), 2018-09/10 — обрезка выгрузки (0 доставок).

-- 2.3.а Наивно: JOIN трёх таблиц сразу (НЕПРАВИЛЬНО)
SELECT COUNT(*)                   AS rows_after_join,
       COUNT(DISTINCT o.order_id) AS orders,
       SUM(p.payment_value)       AS revenue
FROM orders o
JOIN order_items    i ON i.order_id = o.order_id
JOIN order_payments p ON p.order_id = o.order_id
WHERE o.order_status = 'delivered';

-- 2.3.б Правильно: сначала платежи до уровня заказа
WITH pay AS (
    SELECT order_id,
           SUM(payment_value) AS order_payment
    FROM order_payments
    GROUP BY order_id
)
SELECT COUNT(*)               AS orders,
       SUM(pay.order_payment) AS revenue
FROM orders o
JOIN pay ON pay.order_id = o.order_id
WHERE o.order_status = 'delivered';

-- Вывод 2.3: наивный JOIN завышает выручку на 28% (19,78 млн против 15,42 млн).
-- Правило: платежи и товары сначала агрегируем до уровня заказа, потом JOIN.

-- 2.4.а Категории товаров без перевода
SELECT p.product_category_name,
       COUNT(*) AS products
FROM products p
LEFT JOIN product_category_name_translation t
       ON t.product_category_name = p.product_category_name
WHERE t.product_category_name IS NULL
GROUP BY p.product_category_name
ORDER BY products DESC;

-- 2.4.б customer_id против реальных покупателей
SELECT COUNT(*)                           AS customer_ids,
       COUNT(DISTINCT customer_unique_id)      AS unique_customers
FROM customers;

-- Вывод 2.4.а: 610 товаров без категории + 2 категории без перевода (13 товаров).
-- Поэтому FK products → translation не ставили; в отчётах: COALESCE(перевод, оригинал, 'unknown').
-- Вывод 2.4.б: 99 441 customer_id, но 96 096 реальных покупателей (customer_unique_id).
-- Retention и повторные покупки считаем ТОЛЬКО по customer_unique_id.