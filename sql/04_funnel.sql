-- 4.2 Воронка продавцов: конверсия лид → сделка по каналу привлечения
SELECT COALESCE(m.origin, 'unknown')                              AS origin,
       COUNT(*)                                                   AS leads,
       COUNT(d.mql_id)                                            AS deals,
       ROUND(100.0 * COUNT(d.mql_id) / COUNT(*), 1)               AS conversion_pct,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)         AS leads_share_pct
FROM marketing_qualified_leads m
LEFT JOIN closed_deals d ON d.mql_id = m.mql_id
GROUP BY 1
ORDER BY leads DESC;

-- Вывод 4.2: конверсия лид → сделка 10,5% (842 из 8 000). Поиск (organic 11,8%, paid 12,3%) даёт 55% сделок;
-- social — 17% лидов при конверсии 5,6%, email — 3,0%. У «unknown» (14,5% лидов) лучшая конверсия 16,7% —
-- источник не размечен у самых результативных лидов → починить атрибуцию. Без стоимости лида каналы по ROI не сравнить.

-- 4.3 Конверсия и скорость закрытия по месяцу первого контакта (когорты лидов)
SELECT DATE_TRUNC('month', m.first_contact_date)::date              AS lead_month,
       COUNT(*)                                                     AS leads,
       COUNT(d.mql_id)                                              AS deals,
       ROUND(100.0 * COUNT(d.mql_id) / COUNT(*), 1)                 AS conversion_pct,
       PERCENTILE_CONT(0.5) WITHIN GROUP
           (ORDER BY d.won_date::date - m.first_contact_date)       AS median_days,
       ROUND(AVG(d.won_date::date - m.first_contact_date), 0)       AS avg_days
FROM marketing_qualified_leads m
LEFT JOIN closed_deals d ON d.mql_id = m.mql_id
GROUP BY 1
ORDER BY lead_month;

-- 4.3б Проверка гипотезы: распределение сделок по месяцу закрытия
SELECT DATE_TRUNC('month', won_date)::date AS won_month,
       COUNT(*)                            AS deals
FROM closed_deals
GROUP BY 1
ORDER BY won_month;

-- Вывод 4.3: сделки фиксируются только с 12.2017 (первые 3), массово — с 01.2018. Лиды 06–11.2017 закрывались
-- уже в 2018 (медиана 160–400 дн., конверсия 1–4%) — граница данных / старт отдела продаж, не качество работы.
-- Корректная база — лиды 01–04.2018: 651 из 4 695 = 13,9%, медиана закрытия 9–17 дн. (среднее 24–44 — хвост долгих сделок).
-- Май 2018 (10%) занижен цензурированием. Общие 10,5% из 4.2 занижены лидами 2017 года.

-- 4.4 Активация продавцов: подписали → начали продавать → сколько принесли
WITH seller_sales AS (
    SELECT i.seller_id,
           COUNT(DISTINCT i.order_id) AS orders,
           SUM(i.price)               AS gmv
    FROM order_items i
    JOIN orders o ON o.order_id = i.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY i.seller_id
)
SELECT COUNT(*)                                                              	     AS deals,
       COUNT(s.seller_id)                                                    	     AS active_sellers,
       ROUND(100.0 * COUNT(s.seller_id) / COUNT(*), 1)                       	     AS activation_pct,
       COUNT(*) FILTER (WHERE d.won_date < '2018-06-01')                             AS deals_before_jun,
       ROUND(100.0 * COUNT(s.seller_id) FILTER (WHERE d.won_date < '2018-06-01')
                   / COUNT(*)           FILTER (WHERE d.won_date < '2018-06-01'), 1) AS activation_before_jun_pct,
       ROUND(SUM(s.gmv), 0)                                                  	     AS gmv_total,
       ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY s.gmv)::numeric, 0) 	     AS median_gmv_active
FROM closed_deals d
LEFT JOIN seller_sales s ON s.seller_id = d.seller_id;

-- Вывод 4.4: из 842 подписанных продавцов продавали 376 (44,7%); среди подписанных до 06.2018 — 51,3%.
-- Половина продавцов так и не продала ни разу. Оборот активных — 665 тыс. BRL, медиана на продавца — 547 BRL.
-- Рекомендация: онбординг до первой продажи; KPI продаж — «продавцы с первой продажей», а не «закрытые сделки».

-- 4.5 LTV покупателя за 12 месяцев (когорты первой покупки 01–08.2017, у всех ≥ 12 мес. наблюдения)
WITH pay AS (
    SELECT order_id, SUM(payment_value) AS order_value
    FROM order_payments
    GROUP BY order_id
),
cust_orders AS (
    SELECT c.customer_unique_id,
           o.order_purchase_timestamp AS ts,
           pay.order_value
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    JOIN pay         ON pay.order_id  = o.order_id
    WHERE o.order_status = 'delivered'
),
first_buy AS (
    SELECT customer_unique_id,
           MIN(ts) AS first_ts
    FROM cust_orders
    GROUP BY customer_unique_id
)
SELECT COUNT(DISTINCT f.customer_unique_id)                                       AS customers,
       ROUND(SUM(co.order_value) FILTER (WHERE co.ts = f.first_ts)
             / COUNT(DISTINCT f.customer_unique_id), 2)                           AS first_order_value,
       ROUND(SUM(co.order_value) FILTER (WHERE co.ts <= f.first_ts + INTERVAL '365 days')
             / COUNT(DISTINCT f.customer_unique_id), 2)                           AS ltv_12m,
       ROUND(100.0 * SUM(co.order_value) FILTER (WHERE co.ts > f.first_ts
                                                  AND co.ts <= f.first_ts + INTERVAL '365 days')
             / SUM(co.order_value) FILTER (WHERE co.ts <= f.first_ts + INTERVAL '365 days'), 1) AS repeat_share_pct
FROM first_buy f
JOIN cust_orders co ON co.customer_unique_id = f.customer_unique_id
WHERE f.first_ts >= '2017-01-01'
  AND f.first_ts <  '2017-09-01';

-- Вывод 4.5: LTV 12 мес. = 165,96 BRL против 158,81 у первого заказа (+4,5%); повторные заказы — 4,3% LTV.
-- Покупатель ≈ один заказ → привлечение должно окупаться с первой покупки.
-- Макс. CAC = LTV × маржа (комиссия маркетплейса в данных нет). Пример: при 10% → ~16,6 BRL валовой прибыли,
-- при LTV/CAC ≥ 3 → CAC ≤ ~5,5 BRL. Рост retention напрямую поднимает допустимый CAC.