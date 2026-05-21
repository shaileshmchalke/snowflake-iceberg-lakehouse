-- =============================================================================
-- FILE: sql/06_create_unified_view.sql
-- PURPOSE: Standalone DDL for the v_all_trades unified view.
--          Referenced in ADR-005 but previously lacked a dedicated SQL file.
--
-- WHY THIS MATTERS:
--   All 47 Tableau workbooks and 12 Python scripts query v_all_trades ONLY.
--   This view is the zero-downtime cutover mechanism — when the underlying
--   tier tables switch from managed to Iceberg, no consumer SQL changes.
--
-- EXECUTION ORDER: After sql/02_create_iceberg_tables.sql
-- =============================================================================

USE ROLE ICEBERG_ADMIN;
USE DATABASE TRADE_ANALYTICS;
USE SCHEMA TRADE_ANALYTICS.VIEWS;

CREATE OR REPLACE VIEW TRADE_ANALYTICS.VIEWS.V_ALL_TRADES
COMMENT = 'Unified trade view: hot (managed) + warm (Iceberg) + cold (Iceberg).
Query this view only — never query tier tables directly.'
AS

-- HOT TIER: managed table, last 30 days
SELECT
    trade_id, trade_date, trade_timestamp, asset_class, instrument_id,
    instrument_name, instrument_subtype, notional_usd, notional_local,
    local_currency, price, quantity, direction, counterparty_id,
    counterparty_lei, trader_id, book_id, desk_id, entity_id,
    trade_status, settlement_date, value_date, maturity_date,
    uti, mifid_flag, reporting_status, created_at, updated_at,
    source_system,
    YEAR(trade_date)   AS trade_year,
    MONTH(trade_date)  AS trade_month,
    'HOT'              AS storage_tier
FROM TRADE_ANALYTICS.MANAGED.TRADES_HOT

UNION ALL

-- WARM TIER: Iceberg on S3, 30–90 days
SELECT
    trade_id, trade_date, trade_timestamp, asset_class, instrument_id,
    instrument_name, instrument_subtype, notional_usd, notional_local,
    local_currency, price, quantity, direction, counterparty_id,
    counterparty_lei, trader_id, book_id, desk_id, entity_id,
    trade_status, settlement_date, value_date, maturity_date,
    uti, mifid_flag, reporting_status, created_at, updated_at,
    source_system, trade_year, trade_month,
    'WARM'             AS storage_tier
FROM TRADE_ANALYTICS.ICEBERG.TRADES_WARM

UNION ALL

-- COLD TIER: Iceberg on S3, older than 90 days
SELECT
    trade_id, trade_date, trade_timestamp, asset_class, instrument_id,
    instrument_name, instrument_subtype, notional_usd, notional_local,
    local_currency, price, quantity, direction, counterparty_id,
    counterparty_lei, trader_id, book_id, desk_id, entity_id,
    trade_status, settlement_date, value_date, maturity_date,
    uti, mifid_flag, reporting_status, created_at, updated_at,
    source_system, trade_year, trade_month,
    'COLD'             AS storage_tier
FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD;

-- Grants
GRANT SELECT ON VIEW TRADE_ANALYTICS.VIEWS.V_ALL_TRADES
    TO ROLE ICEBERG_READER;
GRANT SELECT ON VIEW TRADE_ANALYTICS.VIEWS.V_ALL_TRADES
    TO ROLE MIGRATION_ROLE;

-- Post-create verification
SELECT storage_tier, COUNT(*) AS rows, MIN(trade_date), MAX(trade_date)
FROM TRADE_ANALYTICS.VIEWS.V_ALL_TRADES
GROUP BY storage_tier ORDER BY storage_tier;
-- Expected: 3 rows (COLD, HOT, WARM)