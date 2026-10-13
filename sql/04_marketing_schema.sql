-- Схема маркетинговой воронки продавцов (отдельно от 01_schema.sql, чтобы не перезагружать основные таблицы)
DROP TABLE IF EXISTS closed_deals, marketing_qualified_leads CASCADE;

CREATE TABLE marketing_qualified_leads (
    mql_id             TEXT PRIMARY KEY,
    first_contact_date DATE,
    landing_page_id    TEXT,
    origin             TEXT
);

CREATE TABLE closed_deals (
    mql_id  TEXT PRIMARY KEY REFERENCES marketing_qualified_leads (mql_id),
    seller_id                     TEXT,
    sdr_id                        TEXT,
    sr_id                         TEXT,
    won_date                      TIMESTAMP,
    business_segment              TEXT,
    lead_type                     TEXT,
    lead_behaviour_profile        TEXT,
    has_company                   BOOLEAN,
    has_gtin                      BOOLEAN,
    average_stock                 TEXT,
    business_type                 TEXT,
    declared_product_catalog_size NUMERIC,
    declared_monthly_revenue      NUMERIC
);