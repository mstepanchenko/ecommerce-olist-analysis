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
       COUNT(DISTINCT customer_unique_id) AS unique_customers
FROM customers;

-- Вывод 2.4.а: 610 товаров без категории + 2 категории без перевода (13 товаров).
-- Поэтому FK products → translation не ставили; в отчётах: COALESCE(перевод, оригинал, 'unknown').
-- Вывод 2.4.б: 99 441 customer_id, но 96 096 реальных покупателей (customer_unique_id).
-- Retention и повторные покупки считаем ТОЛЬКО по customer_unique_id.

-- 2.5.1 Сверка: оплачено vs (цена товаров + доставка), порог 0,01 BRL
WITH items AS (
    SELECT order_id,
           SUM(price + freight_value) AS items_total
    FROM order_items
    GROUP BY order_id
),
pay AS (
    SELECT order_id,
           SUM(payment_value) AS paid
    FROM order_payments
    GROUP BY order_id
)
SELECT COUNT(*)                                                     	 AS orders,
       COUNT(*) FILTER (WHERE ABS(pay.paid - items.items_total) <= 0.01) AS matched,
       COUNT(*) FILTER (WHERE pay.paid - items.items_total >  0.01) 	 AS overpaid,
       COUNT(*) FILTER (WHERE items.items_total - pay.paid > 0.01)    	 AS underpaid,
       ROUND(SUM(pay.paid - items.items_total), 2)                  	 AS total_diff
FROM orders o
JOIN items ON items.order_id = o.order_id
JOIN pay   ON pay.order_id   = o.order_id
WHERE o.order_status = 'delivered';

-- Вывод 2.5.1: 99,69% доставленных заказов сходятся (±0,01 BRL); 260 переплат, 39 недоплат,
-- чистое расхождение +2 831 BRL (0,02% выручки) — несущественно, но причину выясняем в 2.5.2.

-- 2.5.2 Расхождения по способу оплаты и рассрочке
WITH items AS (
    SELECT order_id, SUM(price + freight_value) AS items_total
    FROM order_items
    GROUP BY order_id
),
pay AS (
    SELECT order_id,
           SUM(payment_value)                       AS paid,
           MAX(payment_installments)                AS installments,
           STRING_AGG(DISTINCT payment_type, '+')   AS pay_types
    FROM order_payments
    GROUP BY order_id
),
diff AS (
    SELECT pay.paid - items.items_total AS diff,
           pay.installments,
           pay.pay_types
    FROM orders o
    JOIN items ON items.order_id = o.order_id
    JOIN pay   ON pay.order_id   = o.order_id
    WHERE o.order_status = 'delivered'
      AND ABS(pay.paid - items.items_total) > 0.01
)
SELECT CASE WHEN diff > 0 THEN 'overpaid' ELSE 'underpaid' END AS direction,
       pay_types,
       COUNT(*)                    AS orders,
       ROUND(AVG(diff), 2)         AS avg_diff,
       ROUND(AVG(installments), 1) AS avg_installments
FROM diff
GROUP BY direction, pay_types
ORDER BY direction, orders DESC;

-- 2.5.2-контроль: средняя рассрочка по ВСЕМ платежам картой (для сравнения с 6,5)
SELECT ROUND(AVG(payment_installments), 1) AS avg_installments_all,
       COUNT(*)                            AS card_payments
FROM order_payments
WHERE payment_type = 'credit_card';

-- Вывод 2.5.2: 245 из 260 переплат — кредитная карта со средней рассрочкой 6,5 мес.
-- (по всем платежам картой — 3,5 мес.) → переплата = проценты за рассрочку.
-- Расхождения boleto ±0,02 — округление; 33 недоплаты картой — вероятно, скидки (в данных не отражены).
-- Решение: выручка методологически = price + freight; в 3.1 считали по payment_value
-- (включает проценты рассрочки). Разница 0,02% — несущественно, не пересчитываем, раскрываем в README.

-- 2.5.3 Логические контроли последовательности дат
SELECT
    COUNT(*) FILTER (WHERE order_approved_at < order_purchase_timestamp)                 AS approved_before_purchase,
    COUNT(*) FILTER (WHERE order_delivered_carrier_date < order_purchase_timestamp)      AS shipped_before_purchase,
    COUNT(*) FILTER (WHERE order_delivered_customer_date < order_delivered_carrier_date) AS delivered_before_shipped,
    COUNT(*) FILTER (WHERE order_status = 'delivered'
                       AND order_delivered_customer_date IS NULL)                        AS delivered_without_date,
    COUNT(*) FILTER (WHERE order_status = 'canceled'
                       AND order_delivered_customer_date IS NOT NULL)                    AS canceled_but_delivered
FROM orders;

-- Вывод 2.5.3: нарушений последовательности дат ~200 из 99 441 (0,2%): отгрузка раньше покупки 166,
-- доставка раньше отгрузки 23, delivered без даты 8, canceled с датой доставки 6.
-- Из данных не удаляем; в 3.4 (сроки доставки) исключаем 23 + 8 и раскрываем.

-- 2.5.4.а Выбросы цены и доставки (уровень позиции заказа)
SELECT COUNT(*)                                                               AS items,
       ROUND(PERCENTILE_CONT(0.5)  WITHIN GROUP (ORDER BY price)::numeric, 2) AS median_price,
       ROUND(PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY price)::numeric, 2) AS p99_price,
       MAX(price)                                                             AS max_price,
       COUNT(*) FILTER (WHERE freight_value > price)                          AS freight_gt_price
FROM order_items;

-- 2.5.4.б Полнота: доставленные заказы без отзыва
SELECT COUNT(*) AS delivered_without_review
FROM orders o
LEFT JOIN order_reviews r ON r.order_id = o.order_id
WHERE o.order_status = 'delivered'
  AND r.order_id IS NULL;

-- Вывод 2.5.4: цена — длинный хвост (медиана 74,99, p99 890, max 6 735) → для «типичного» чека — медиана.
-- 4 124 позиции (3,7%) с доставкой дороже товара — кандидаты в убыточные, разобрать по категориям в 3.5.
-- 646 доставленных заказов (0,7%) без отзыва — в 3.4 анализ оценок только по заказам с отзывом.