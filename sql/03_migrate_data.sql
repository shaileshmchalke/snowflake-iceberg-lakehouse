-- =============================================================================
-- FILE: sql/03_migrate_data.sql
-- PURPOSE: Month-by-month historical data migration from Snowflake managed
--          tables to Iceberg on S3.
--
-- STRATEGY: Snapshot-first migration (see docs/lessons-learned.md, Failure 4)
--           1. CLONE source partition → immutable snapshot
--           2. INSERT INTO Iceberg FROM clone
--           3. Validate counts and checksums against clone
--           4. Drop clone
--           5. Move to next month
--
-- DO NOT run this script as a whole. Each month is a separate transaction.
-- Use scripts/migrate_table.sh to orchestrate month-by-month execution.
--
-- ESTIMATED RUNTIME: 8-15 minutes per month on LARGE warehouse (450TB total)
-- ESTIMATED COST:    ~50-80 credits per month = ~3,200 credits total
-- =============================================================================

USE ROLE MIGRATION_ROLE;
USE WAREHOUSE MIGRATION_WH;
USE DATABASE TRADE_ANALYTICS;

-- =============================================================================
-- TEMPLATE: Single-Month Migration
-- Replace :start_date, :end_date, :snap_suffix before executing.
-- scripts/migrate_table.sh generates and executes this per month.
-- =============================================================================

-- -------------------------------------------------------------------------
-- PHASE A: Pre-migration checks
-- -------------------------------------------------------------------------

-- A1: Confirm target Iceberg table exists and is reachable
SELECT COUNT(*) AS iceberg_row_count FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD
WHERE trade_year  = YEAR(TO_DATE('2021-01-01'))
  AND trade_month = MONTH(TO_DATE('2021-01-01'));
-- Expected: 0 (empty before migration for this partition)

-- A2: Count source rows for the migration window
SELECT COUNT(*) AS source_row_count
FROM TRADE_ANALYTICS.MANAGED.TRADES_COLD_LEGACY  -- original pre-migration managed table
WHERE trade_date >= '2021-01-01'
  AND trade_date <  '2021-02-01';
-- Record this number. It is your validation target.

-- -------------------------------------------------------------------------
-- PHASE B: Create snapshot clone (immutable migration source)
-- -------------------------------------------------------------------------

-- B1: Drop prior snapshot if it exists (idempotent re-run safety)
DROP TABLE IF EXISTS TRADE_ANALYTICS.MANAGED.MIGRATION_SNAP_202101;

-- B2: Clone the source partition into a snapshot table
--     CLONE is zero-copy in Snowflake — no data is physically duplicated
--     until the original changes. Cost: near-zero.
CREATE TABLE TRADE_ANALYTICS.MANAGED.MIGRATION_SNAP_202101
    CLONE TRADE_ANALYTICS.MANAGED.TRADES_COLD_LEGACY;

-- B3: Verify snapshot row count matches pre-migration count
SELECT COUNT(*) AS snapshot_row_count
FROM TRADE_ANALYTICS.MANAGED.MIGRATION_SNAP_202101
WHERE trade_date >= '2021-01-01'
  AND trade_date <  '2021-02-01';
-- Must match source_row_count from A2. If not, STOP and investigate.

-- -------------------------------------------------------------------------
-- PHASE C: Migrate data from snapshot to Iceberg
-- -------------------------------------------------------------------------

-- C1: Execute the INSERT (this is the actual migration step)
INSERT INTO TRADE_ANALYTICS.ICEBERG.TRADES_COLD (
    trade_id, trade_date, trade_timestamp, asset_class, instrument_id,
    instrument_name, instrument_subtype, notional_usd, notional_local,
    local_currency, price, quantity, direction, counterparty_id,
    counterparty_lei, trader_id, book_id, desk_id, entity_id, trade_status,
    settlement_date, value_date, maturity_date, uti, mifid_flag,
    reporting_status, created_at, updated_at, source_system,
    trade_year, trade_month
)
SELECT
    trade_id,
    trade_date,
    trade_timestamp,
    asset_class,
    instrument_id,
    instrument_name,
    instrument_subtype,
    notional_usd,
    notional_local,
    local_currency,
    price,
    quantity,
    direction,
    counterparty_id,
    counterparty_lei,
    trader_id,
    book_id,
    desk_id,
    entity_id,
    trade_status,
    settlement_date,
    value_date,
    maturity_date,
    uti,
    mifid_flag,
    reporting_status,
    created_at,
    updated_at,
    source_system,
    -- Materialize partition columns (required — see ADR-003)
    YEAR(trade_date)  AS trade_year,
    MONTH(trade_date) AS trade_month
FROM TRADE_ANALYTICS.MANAGED.MIGRATION_SNAP_202101
WHERE trade_date >= '2021-01-01'
  AND trade_date <  '2021-02-01';

-- -------------------------------------------------------------------------
-- PHASE D: Post-migration validation
-- (Full validation also in sql/05_validation_queries.sql)
-- -------------------------------------------------------------------------

-- D1: Row count validation
WITH source_counts AS (
    SELECT COUNT(*) AS src_rows
    FROM TRADE_ANALYTICS.MANAGED.MIGRATION_SNAP_202101
    WHERE trade_date >= '2021-01-01'
      AND trade_date <  '2021-02-01'
),
target_counts AS (
    SELECT COUNT(*) AS tgt_rows
    FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD
    WHERE trade_year  = 2021
      AND trade_month = 1
)
SELECT
    src_rows,
    tgt_rows,
    src_rows - tgt_rows AS delta,
    CASE
        WHEN src_rows = tgt_rows THEN 'PASS ✓'
        ELSE 'FAIL ✗ — DO NOT PROCEED'
    END AS validation_result
FROM source_counts, target_counts;

-- D2: Notional sum validation (catches truncation or data type issues)
WITH source_sums AS (
    SELECT SUM(notional_usd) AS src_notional
    FROM TRADE_ANALYTICS.MANAGED.MIGRATION_SNAP_202101
    WHERE trade_date >= '2021-01-01'
      AND trade_date <  '2021-02-01'
),
target_sums AS (
    SELECT SUM(notional_usd) AS tgt_notional
    FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD
    WHERE trade_year  = 2021
      AND trade_month = 1
)
SELECT
    src_notional,
    tgt_notional,
    ABS(src_notional - tgt_notional) AS abs_delta,
    CASE
        WHEN ABS(src_notional - tgt_notional) < 0.01 THEN 'PASS ✓'
        ELSE 'FAIL ✗ — notional mismatch, check data types'
    END AS validation_result
FROM source_sums, target_sums;

-- D3: Asset class distribution check
SELECT
    'SOURCE' AS data_source,
    asset_class,
    COUNT(*) AS row_count
FROM TRADE_ANALYTICS.MANAGED.MIGRATION_SNAP_202101
WHERE trade_date >= '2021-01-01'
  AND trade_date <  '2021-02-01'
GROUP BY asset_class

UNION ALL

SELECT
    'TARGET',
    asset_class,
    COUNT(*)
FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD
WHERE trade_year  = 2021
  AND trade_month = 1
GROUP BY asset_class
ORDER BY data_source, asset_class;
-- Every row in SOURCE should have a matching row in TARGET with the same count.

-- D4: NULL check on critical columns
SELECT
    COUNT(*) FILTER (WHERE trade_id IS NULL)       AS null_trade_id,
    COUNT(*) FILTER (WHERE trade_date IS NULL)     AS null_trade_date,
    COUNT(*) FILTER (WHERE notional_usd IS NULL)   AS null_notional,
    COUNT(*) FILTER (WHERE asset_class IS NULL)    AS null_asset_class,
    COUNT(*) FILTER (WHERE direction IS NULL)      AS null_direction,
    COUNT(*) FILTER (WHERE trade_year IS NULL)     AS null_trade_year,
    COUNT(*) FILTER (WHERE trade_month IS NULL)    AS null_trade_month
FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD
WHERE trade_year  = 2021
  AND trade_month = 1;
-- All values must be 0. Any non-zero = data quality failure.

-- -------------------------------------------------------------------------
-- PHASE E: Cleanup (ONLY after all validations PASS)
-- -------------------------------------------------------------------------

-- E1: Drop migration snapshot
DROP TABLE TRADE_ANALYTICS.MANAGED.MIGRATION_SNAP_202101;

-- E2: Log completion (optional audit table)
INSERT INTO TRADE_ANALYTICS.MANAGED.MIGRATION_LOG (
    migration_run_id,
    source_table,
    target_table,
    partition_start,
    partition_end,
    rows_migrated,
    migration_ts,
    status
)
SELECT
    UUID_STRING()                                   AS migration_run_id,
    'TRADES_COLD_LEGACY'                            AS source_table,
    'ICEBERG.TRADES_COLD'                           AS target_table,
    '2021-01-01'::DATE                              AS partition_start,
    '2021-01-31'::DATE                              AS partition_end,
    COUNT(*)                                        AS rows_migrated,
    CURRENT_TIMESTAMP()                             AS migration_ts,
    'COMPLETED'                                     AS status
FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD
WHERE trade_year = 2021 AND trade_month = 1;

-- =============================================================================
-- MIGRATION LOG TABLE (run once before starting migration)
-- =============================================================================
CREATE TABLE IF NOT EXISTS TRADE_ANALYTICS.MANAGED.MIGRATION_LOG (
    migration_run_id  VARCHAR(36)    DEFAULT UUID_STRING(),
    source_table      VARCHAR(200)   NOT NULL,
    target_table      VARCHAR(200)   NOT NULL,
    partition_start   DATE           NOT NULL,
    partition_end     DATE           NOT NULL,
    rows_migrated     NUMBER         NOT NULL,
    migration_ts      TIMESTAMP_NTZ  DEFAULT CURRENT_TIMESTAMP(),
    status            VARCHAR(20)    DEFAULT 'COMPLETED',
    notes             VARCHAR(2000)
)
COMMENT = 'Audit log for Iceberg migration progress';

-- =============================================================================
-- POST-COMPACTION (run after all months for a given year are migrated)
-- Small files accumulate during per-month migration. Compaction merges them
-- into target 512MB-1GB files for optimal read performance.
-- Run once per year-partition after all 12 months are migrated.
-- =============================================================================

-- Compact TRADES_COLD partition for year 2021 (after all 12 months migrated)
ALTER ICEBERG TABLE TRADE_ANALYTICS.ICEBERG.TRADES_COLD
    EXECUTE FILE_COMPACTION
    WHERE trade_year = 2021;

-- Verify compaction result
SELECT SYSTEM$GET_ICEBERG_TABLE_INFORMATION('TRADE_ANALYTICS.ICEBERG.TRADES_COLD');

-- =============================================================================
-- END OF SCRIPT 03
-- NEXT: Run sql/04_performance_benchmarks.sql to validate query performance
-- =============================================================================