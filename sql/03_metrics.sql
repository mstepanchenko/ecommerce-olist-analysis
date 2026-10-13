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
-- Пик — ноябрь 2017 (Black Friday): 7 289 заказов, 1 078 607 BRL выручки (AOV ≈ 148).

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

-- 3.3.1 Подготовка когорт: покупатель — месяц заказа — месяц когорты — номер месяца
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
)
SELECT customer_unique_id,
       cohort_month,
       order_month,
       (DATE_PART('year',  order_month) - DATE_PART('year',  cohort_month)) * 12
     + (DATE_PART('month', order_month) - DATE_PART('month', cohort_month)) AS month_number
FROM cohorts
ORDER BY month_number DESC
LIMIT 10;

-- 3.3.2 Когортная таблица retention (% покупателей когорты, купивших снова через N месяцев)
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
FROM cohort_counts
ORDER BY cohort_month;

-- Вывод 3.3: retention через 1 мес. — 0,2–0,7%, через 6 мес. — ~0,1–0,4%; кривая плоская
-- (резкого падения после 1-го месяца нет — возвращаться почти некому с самого начала).
-- Удержание не улучшилось за 2017–2018, хотя новых клиентов стало в 8 раз больше.
-- Ячейки за пределами данных (цензурирование справа) — NULL, а не 0, чтобы не занижать средние.

-- 3.4.1 Средняя оценка: доставка вовремя vs с опозданием
WITH rev AS (
    SELECT order_id,
           AVG(review_score) AS score
    FROM order_reviews
    GROUP BY order_id
),
d AS (
    SELECT CASE WHEN o.order_delivered_customer_date::date > o.order_estimated_delivery_date::date
                THEN 'late' ELSE 'on_time' END AS delivery,
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
SELECT delivery,
       COUNT(*)                                                        AS orders,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)              AS pct_orders,
       ROUND(AVG(score), 2)                                            AS avg_score,
       ROUND(100.0 * COUNT(*) FILTER (WHERE score <= 2) / COUNT(*), 1) AS bad_review_pct
FROM d
GROUP BY delivery;

-- Вывод 3.4.1: 6,7% заказов доставлены с опозданием; средняя оценка 2,27 против 4,29,
-- плохих отзывов 62,4% против 9,2% (в 6,8 раза больше). Связь ≠ причинность: проверяем «дозу» в 3.4.2.

-- 3.4.2. Чем больше опоздание, тем хуже оценка?
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
GROUP BY delay_bucket
ORDER BY delay_bucket;

-- Вывод 3.4.2: «доза → эффект»: оценка падает с каждой корзиной опоздания (4,29 → 3,29 → 2,11 → 1,67),
-- насыщение после 7 дней (~1,7). Даже 1–3 дня = −1 балл и ×3,5 плохих отзывов.
-- Гипотеза для A/B-теста: консервативная обещанная дата (обещание важнее скорости).

-- 3.4.3 Повторные покупки в зависимости от опоздания ПЕРВОГО заказа
WITH ord AS (
    SELECT c.customer_unique_id,
           o.order_delivered_customer_date,
           o.order_estimated_delivery_date,
           ROW_NUMBER() OVER (PARTITION BY c.customer_unique_id
                       ORDER BY o.order_purchase_timestamp)      AS rn,
           COUNT(*) OVER (PARTITION BY c.customer_unique_id)     AS n_orders
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.order_status = 'delivered'
      AND o.order_purchase_timestamp >= '2017-01-01'
      AND o.order_purchase_timestamp <  '2018-09-01'
      AND o.order_delivered_customer_date IS NOT NULL
)
SELECT CASE WHEN order_delivered_customer_date::date > order_estimated_delivery_date::date
            THEN 'late' ELSE 'on_time' END                                  AS first_delivery,
       COUNT(*)                                                             AS customers,
       ROUND(100.0 * COUNT(*) FILTER (WHERE n_orders > 1) / COUNT(*), 2)  AS repeat_pct
FROM ord
WHERE rn = 1
GROUP BY first_delivery;

-- Вывод 3.4.3: при опоздании ПЕРВОГО заказа повторно покупают 2,58% против 3,03% (−15% относительно);
-- z ≈ 2,0, p ≈ 0,04 — на грани значимости. Проверяем устойчивость к «не успел вернуться» в 3.4.4.

-- 3.4.4 Проверка устойчивости
WITH ord AS (
    SELECT c.customer_unique_id,
           o.order_delivered_customer_date,
           o.order_estimated_delivery_date,
           o.order_purchase_timestamp,
           ROW_NUMBER() OVER (PARTITION BY c.customer_unique_id
                       ORDER BY o.order_purchase_timestamp)      AS rn,
           COUNT(*) OVER (PARTITION BY c.customer_unique_id)     AS n_orders
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.order_status = 'delivered'
      AND o.order_purchase_timestamp >= '2017-01-01'
      AND o.order_purchase_timestamp <  '2018-09-01'
      AND o.order_delivered_customer_date IS NOT NULL
)
SELECT CASE WHEN order_delivered_customer_date::date > order_estimated_delivery_date::date
            THEN 'late' ELSE 'on_time' END                                  AS first_delivery,
       COUNT(*)                                                             AS customers,
       ROUND(100.0 * COUNT(*) FILTER (WHERE n_orders > 1) / COUNT(*), 2)  AS repeat_pct
FROM ord
WHERE rn = 1
  AND order_purchase_timestamp < '2018-03-01'
GROUP BY first_delivery;

-- Вывод 3.4.4 (устойчивость): только первые покупки до 2018-03-01 (≥ 6 мес. на возврат):
-- повторно 3,13% (опоздание) против 4,04% (вовремя), −23%, z ≈ 2,7, p ≈ 0,007. Вывод устойчив и усилился.

-- ИТОГ 3.4: опоздание — рычаг для обеих главных проблем: оценка (2,27 против 4,29, доза → эффект)
-- и повторные покупки (−23%). Ограничение: связь, а не доказанная причинность (возможны общие причины —
-- продавец, категория, регион); для причинного вывода — A/B-тест обещанной даты доставки.