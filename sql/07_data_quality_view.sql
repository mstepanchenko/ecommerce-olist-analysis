-- =========================================================
-- 07_data_quality_view.sql — реестр контролей качества данных
-- 1 строка = 1 проверка из 02_data_quality.sql
-- Порог существенности: 1% для записей, 0,5% для денег
-- =========================================================

CREATE OR REPLACE VIEW v_dq_checks AS
WITH
items AS (
    SELECT order_id, SUM(price + freight_value) AS items_total
    FROM order_items
    GROUP BY order_id
),
pay AS (
    SELECT order_id, SUM(payment_value) AS paid
    FROM order_payments
    GROUP BY order_id
),
recon AS (                                   -- 2.5.1: сверка по доставленным заказам
    SELECT pay.paid, items.items_total, pay.paid - items.items_total AS diff
    FROM orders o
    JOIN items ON items.order_id = o.order_id
    JOIN pay   ON pay.order_id   = o.order_id
    WHERE o.order_status = 'delivered'
),
fanout AS (                                  -- 2.3: наивный JOIN против правильного
    SELECT
        (SELECT SUM(p.payment_value)
         FROM orders o
         JOIN order_items    i ON i.order_id = o.order_id
         JOIN order_payments p ON p.order_id = o.order_id
         WHERE o.order_status = 'delivered')           AS naive_revenue,
        (SELECT SUM(pay.paid)
         FROM orders o
         JOIN pay ON pay.order_id = o.order_id
         WHERE o.order_status = 'delivered')           AS correct_revenue
),
dates AS (                                   -- 2.5.3: последовательность дат
    SELECT
        COUNT(*) AS orders,
        COUNT(*) FILTER (WHERE order_approved_at < order_purchase_timestamp)                 AS approved_before_purchase,
        COUNT(*) FILTER (WHERE order_delivered_carrier_date < order_purchase_timestamp)      AS shipped_before_purchase,
        COUNT(*) FILTER (WHERE order_delivered_customer_date < order_delivered_carrier_date) AS delivered_before_shipped,
        COUNT(*) FILTER (WHERE order_status = 'delivered'
                           AND order_delivered_customer_date IS NULL)                        AS delivered_without_date,
        COUNT(*) FILTER (WHERE order_status = 'canceled'
                           AND order_delivered_customer_date IS NOT NULL)                    AS canceled_but_delivered
    FROM orders
),
cat AS (                                     -- 2.4.а: товары без категории или перевода
    SELECT COUNT(*)                                                   AS products,
           COUNT(*) FILTER (WHERE t.product_category_name IS NULL)    AS no_translation
    FROM products p
    LEFT JOIN product_category_name_translation t
           ON t.product_category_name = p.product_category_name
),
cust AS (                                    -- 2.4.б: customer_id против реальных покупателей
    SELECT COUNT(*) AS ids, COUNT(DISTINCT customer_unique_id) AS uniq
    FROM customers
),
rev AS (                                     -- 2.5.4.б: доставленные заказы без отзыва
    SELECT COUNT(*) AS delivered,
           COUNT(*) FILTER (WHERE r.order_id IS NULL) AS no_review
    FROM orders o
    LEFT JOIN (SELECT DISTINCT order_id FROM order_reviews) r ON r.order_id = o.order_id
    WHERE o.order_status = 'delivered'
),
checks (check_no, area, check_name, unit, checked, issues, threshold_pct, decision) AS (
    SELECT 1, 'Сверка', 'Оплачено = товары + доставка (±0,01 BRL)', 'заказы',
           COUNT(*), COUNT(*) FILTER (WHERE ABS(diff) > 0.01), 1.0,
           'Переплаты — проценты рассрочки по картам (245 из 260), недоплаты — вероятно скидки'
    FROM recon
    UNION ALL
    SELECT 2, 'Сверка', 'Чистое расхождение оплат и товаров', 'BRL',
           ROUND(SUM(items_total)), ABS(ROUND(SUM(diff))), 0.5,
           'Несущественно: выручка по payment_value, расхождение раскрыто в README'
    FROM recon
    UNION ALL
    SELECT 3, 'Методика', 'Завышение выручки при JOIN без агрегации (fan-out)', 'BRL',
           ROUND(correct_revenue), ROUND(naive_revenue - correct_revenue), 0.5,
           'Платежи и товары агрегируются до уровня заказа до JOIN'
    FROM fanout
    UNION ALL
    SELECT 4, 'Даты', 'Одобрен раньше покупки', 'заказы',
           orders, approved_before_purchase, 1.0, 'Нарушений нет'
    FROM dates
    UNION ALL
    SELECT 5, 'Даты', 'Отгружен раньше покупки', 'заказы',
           orders, shipped_before_purchase, 1.0, 'Не влияет на сроки доставки клиенту — оставлены'
    FROM dates
    UNION ALL
    SELECT 6, 'Даты', 'Доставлен раньше отгрузки', 'заказы',
           orders, delivered_before_shipped, 1.0, 'Исключены из анализа сроков (3.4)'
    FROM dates
    UNION ALL
    SELECT 7, 'Даты', 'Статус delivered без даты доставки', 'заказы',
           orders, delivered_without_date, 1.0, 'Исключены из анализа сроков (is_late = NULL)'
    FROM dates
    UNION ALL
    SELECT 8, 'Даты', 'Отменён, но есть дата доставки', 'заказы',
           orders, canceled_but_delivered, 1.0, 'Вне анализа: учитываются только delivered'
    FROM dates
    UNION ALL
    SELECT 9, 'Справочники', 'Товар без категории или перевода', 'товары',
           products, no_translation, 1.0, 'В отчётах COALESCE(перевод, оригинал, ''unknown'')'
    FROM cat
    UNION ALL
    SELECT 10, 'Справочники', 'Один покупатель под несколькими customer_id', 'записи',
    	   ids, ids - uniq, 1.0, 'Повторные покупки и когорты — только по customer_unique_id'
    FROM cust
    UNION ALL
    SELECT 11, 'Полнота', 'Доставленный заказ без отзыва', 'заказы',
           delivered, no_review, 1.0, 'Оценки анализируются только по заказам с отзывом'
    FROM rev
)
SELECT check_no, area, check_name, unit, checked, issues,
       ROUND(100.0 * issues / NULLIF(checked, 0), 2)                         AS issues_pct,
       threshold_pct,
       CASE WHEN 100.0 * issues / NULLIF(checked, 0) <= threshold_pct
            THEN 1 ELSE 0 END                                                AS within_threshold,
       decision
FROM checks;