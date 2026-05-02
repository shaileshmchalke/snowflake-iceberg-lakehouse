-- =============================================================================
-- FILE: sql/05_validation_queries.sql
-- PURPOSE: Production-grade data quality validation suite for post-migration
--          verification. Run these queries against every migrated partition
--          before declaring migration complete and dropping managed table data.
--
-- VALIDATION LEVELS:
--   Level 1 — Structural:   Table exists, partition spec correct, schema matches
--   Level 2 — Volume:       Row counts match source, no duplicates
--   Level 3 — Content:      Numeric aggregates match, critical columns non-null
--   Level 4 — Referential:  All asset classes present, date range intact
--   Level 5 — Sampling:     Random row-level spot checks (MD5 hash comparison)
--
-- ALL QUERIES MUST RETURN "PASS" BEFORE PROCEEDING.
-- =============================================================================

USE ROLE ICEBERG_READER;
USE WAREHOUSE ANALYST_WH;
USE DATABASE TRADE_ANALYTICS;

-- Parameterize the validation window
SET VALIDATE_YEAR  = 2021;
SET VALIDATE_MONTH = 1;
SET START_DATE     = '2021-01-01';
SET END_DATE       = '2021-01-31';

-- =============================================================================
-- LEVEL 1: STRUCTURAL VALIDATION
-- =============================================================================

-- 1.1: Confirm Iceberg table exists and is accessible
SELECT
    table_name,
    table_type,
    comment
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_CATALOG = 'TRADE_ANALYTICS'
  AND TABLE_SCHEMA  = 'ICEBERG'
  AND TABLE_NAME    IN ('TRADES_WARM', 'TRADES_COLD');
-- Expected: 2 rows returned

-- 1.2: Schema drift check — confirm column count and data types match
SELECT
    c.column_name,
    c.data_type,
    c.is_nullable,
    c.character_maximum_length,
    c.numeric_precision
FROM INFORMATION_SCHEMA.COLUMNS c
WHERE c.TABLE_CATALOG = 'TRADE_ANALYTICS'
  AND c.TABLE_SCHEMA  = 'ICEBERG'
  AND c.TABLE_NAME    = 'TRADES_COLD'
ORDER BY c.ordinal_position;
-- Compare this output to the source managed table schema.
-- Any missing column = migration DDL bug. Stop and fix.

-- =============================================================================
-- LEVEL 2: VOLUME VALIDATION
-- =============================================================================

-- 2.1: Row count comparison
WITH source AS (
    SELECT COUNT(*) AS cnt
    FROM TRADE_ANALYTICS.MANAGED.TRADES_COLD_LEGACY
    WHERE trade_date >= $START_DATE
      AND trade_date <= $END_DATE
),
target AS (
    SELECT COUNT(*) AS cnt
    FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD
    WHERE trade_year  = $VALIDATE_YEAR
      AND trade_month = $VALIDATE_MONTH
)
SELECT
    source.cnt AS source_rows,
    target.cnt AS target_rows,
    source.cnt - target.cnt AS delta,
    CASE
        WHEN source.cnt = target.cnt THEN 'LEVEL2-1 PASS ✓'
        ELSE 'LEVEL2-1 FAIL ✗  delta=' || (source.cnt - target.cnt)::VARCHAR
    END AS result
FROM source, target;

-- 2.2: Duplicate check (trade_id must be unique)
SELECT
    CASE
        WHEN COUNT(*) = COUNT(DISTINCT trade_id)
        THEN 'LEVEL2-2 PASS ✓ (no duplicate trade_id)'
        ELSE 'LEVEL2-2 FAIL ✗  duplicates found: '
             || (COUNT(*) - COUNT(DISTINCT trade_id))::VARCHAR
    END AS result
FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD
WHERE trade_year  = $VALIDATE_YEAR
  AND trade_month = $VALIDATE_MONTH;

-- 2.3: If duplicates found — identify them
-- (Only run if 2.2 fails)
SELECT
    trade_id,
    COUNT(*) AS occurrences
FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD
WHERE trade_year  = $VALIDATE_YEAR
  AND trade_month = $VALIDATE_MONTH
GROUP BY trade_id
HAVING COUNT(*) > 1
ORDER BY occurrences DESC
LIMIT 50;

-- =============================================================================
-- LEVEL 3: CONTENT VALIDATION
-- =============================================================================

-- 3.1: Notional sum comparison (financial accuracy check)
WITH source_sums AS (
    SELECT
        SUM(notional_usd)   AS total_notional,
        SUM(quantity)       AS total_quantity,
        MIN(trade_date)     AS min_date,
        MAX(trade_date)     AS max_date
    FROM TRADE_ANALYTICS.MANAGED.TRADES_COLD_LEGACY
    WHERE trade_date >= $START_DATE
      AND trade_date <= $END_DATE
),
target_sums AS (
    SELECT
        SUM(notional_usd)   AS total_notional,
        SUM(quantity)       AS total_quantity,
        MIN(trade_date)     AS min_date,
        MAX(trade_date)     AS max_date
    FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD
    WHERE trade_year  = $VALIDATE_YEAR
      AND trade_month = $VALIDATE_MONTH
)
SELECT
    source_sums.total_notional AS src_notional,
    target_sums.total_notional AS tgt_notional,
    ABS(source_sums.total_notional - target_sums.total_notional) AS abs_delta,
    source_sums.min_date  AS src_min_date,
    target_sums.min_date  AS tgt_min_date,
    source_sums.max_date  AS src_max_date,
    target_sums.max_date  AS tgt_max_date,
    CASE
        WHEN ABS(source_sums.total_notional - target_sums.total_notional) < 0.01
         AND source_sums.min_date = target_sums.min_date
         AND source_sums.max_date = target_sums.max_date
        THEN 'LEVEL3-1 PASS ✓'
        ELSE 'LEVEL3-1 FAIL ✗'
    END AS result
FROM source_sums, target_sums;

-- 3.2: NULL check on NOT NULL columns
SELECT
    COUNT(*) FILTER (WHERE trade_id        IS NULL)  AS null_trade_id,
    COUNT(*) FILTER (WHERE trade_date      IS NULL)  AS null_trade_date,
    COUNT(*) FILTER (WHERE trade_timestamp IS NULL)  AS null_trade_ts,
    COUNT(*) FILTER (WHERE asset_class     IS NULL)  AS null_asset_class,
    COUNT(*) FILTER (WHERE notional_usd    IS NULL)  AS null_notional,
    COUNT(*) FILTER (WHERE direction       IS NULL)  AS null_direction,
    COUNT(*) FILTER (WHERE trade_year      IS NULL)  AS null_trade_year,
    COUNT(*) FILTER (WHERE trade_month     IS NULL)  AS null_trade_month,
    COUNT(*) FILTER (WHERE created_at      IS NULL)  AS null_created_at,
    CASE
        WHEN COUNT(*) FILTER (WHERE trade_id IS NULL)        = 0
         AND COUNT(*) FILTER (WHERE trade_date IS NULL)      = 0
         AND COUNT(*) FILTER (WHERE notional_usd IS NULL)    = 0
         AND COUNT(*) FILTER (WHERE asset_class IS NULL)     = 0
         AND COUNT(*) FILTER (WHERE direction IS NULL)       = 0
        THEN 'LEVEL3-2 PASS ✓'
        ELSE 'LEVEL3-2 FAIL ✗  unexpected NULLs in NOT NULL columns'
    END AS result
FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD
WHERE trade_year  = $VALIDATE_YEAR
  AND trade_month = $VALIDATE_MONTH;

-- 3.3: Invalid direction values
SELECT
    direction,
    COUNT(*) AS occurrences
FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD
WHERE trade_year  = $VALIDATE_YEAR
  AND trade_month = $VALIDATE_MONTH
  AND direction NOT IN ('BUY', 'SELL')
GROUP BY direction;
-- Expected: 0 rows. Any result = data quality issue.

-- 3.4: Partition column consistency (trade_year / trade_month must match trade_date)
SELECT
    COUNT(*) AS mismatched_partition_columns
FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD
WHERE trade_year  = $VALIDATE_YEAR
  AND trade_month = $VALIDATE_MONTH
  AND (
    YEAR(trade_date)  != trade_year
    OR MONTH(trade_date) != trade_month
  );
-- Expected: 0. Any non-zero = partition column materialization bug in migration INSERT.

-- =============================================================================
-- LEVEL 4: REFERENTIAL VALIDATION
-- =============================================================================

-- 4.1: Asset class distribution (compare source vs target)
SELECT
    COALESCE(src.asset_class, tgt.asset_class) AS asset_class,
    src.src_count,
    tgt.tgt_count,
    CASE
        WHEN src.src_count = tgt.tgt_count THEN 'PASS ✓'
        ELSE 'FAIL ✗ delta=' || (src.src_count - tgt.tgt_count)::VARCHAR
    END AS result
FROM (
    SELECT asset_class, COUNT(*) AS src_count
    FROM TRADE_ANALYTICS.MANAGED.TRADES_COLD_LEGACY
    WHERE trade_date >= $START_DATE AND trade_date <= $END_DATE
    GROUP BY asset_class
) src
FULL OUTER JOIN (
    SELECT asset_class, COUNT(*) AS tgt_count
    FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD
    WHERE trade_year = $VALIDATE_YEAR AND trade_month = $VALIDATE_MONTH
    GROUP BY asset_class
) tgt
ON src.asset_class = tgt.asset_class
ORDER BY asset_class;

-- 4.2: Daily row count profile (catches missing days)
SELECT
    src.trade_date,
    src.src_daily_count,
    tgt.tgt_daily_count,
    src.src_daily_count - COALESCE(tgt.tgt_daily_count, 0) AS delta,
    CASE
        WHEN src.src_daily_count = COALESCE(tgt.tgt_daily_count, 0)
        THEN 'PASS ✓'
        ELSE 'FAIL ✗'
    END AS result
FROM (
    SELECT trade_date, COUNT(*) AS src_daily_count
    FROM TRADE_ANALYTICS.MANAGED.TRADES_COLD_LEGACY
    WHERE trade_date >= $START_DATE AND trade_date <= $END_DATE
    GROUP BY trade_date
) src
LEFT JOIN (
    SELECT trade_date, COUNT(*) AS tgt_daily_count
    FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD
    WHERE trade_year = $VALIDATE_YEAR AND trade_month = $VALIDATE_MONTH
    GROUP BY trade_date
) tgt
ON src.trade_date = tgt.trade_date
ORDER BY src.trade_date;

-- =============================================================================
-- LEVEL 5: SAMPLING — ROW-LEVEL HASH COMPARISON
-- Compares MD5 of all columns for a random sample of 1,000 rows.
-- Catches column-level data corruption not visible in aggregates.
-- =============================================================================

-- 5.1: Extract 1000 random trade_ids from source
CREATE OR REPLACE TEMPORARY TABLE validation_sample_ids AS
SELECT trade_id
FROM TRADE_ANALYTICS.MANAGED.TRADES_COLD_LEGACY
WHERE trade_date >= $START_DATE
  AND trade_date <= $END_DATE
ORDER BY RANDOM()
LIMIT 1000;

-- 5.2: Hash source rows for the sample
CREATE OR REPLACE TEMPORARY TABLE validation_source_hashes AS
SELECT
    trade_id,
    MD5(
        CONCAT_WS('|',
            COALESCE(trade_id, ''),
            COALESCE(trade_date::VARCHAR, ''),
            COALESCE(trade_timestamp::VARCHAR, ''),
            COALESCE(asset_class, ''),
            COALESCE(instrument_id, ''),
            COALESCE(notional_usd::VARCHAR, ''),
            COALESCE(direction, ''),
            COALESCE(counterparty_id, ''),
            COALESCE(trader_id, ''),
            COALESCE(book_id, ''),
            COALESCE(trade_status, '')
        )
    ) AS row_hash
FROM TRADE_ANALYTICS.MANAGED.TRADES_COLD_LEGACY
WHERE trade_id IN (SELECT trade_id FROM validation_sample_ids);

-- 5.3: Hash target rows for the same sample
CREATE OR REPLACE TEMPORARY TABLE validation_target_hashes AS
SELECT
    trade_id,
    MD5(
        CONCAT_WS('|',
            COALESCE(trade_id, ''),
            COALESCE(trade_date::VARCHAR, ''),
            COALESCE(trade_timestamp::VARCHAR, ''),
            COALESCE(asset_class, ''),
            COALESCE(instrument_id, ''),
            COALESCE(notional_usd::VARCHAR, ''),
            COALESCE(direction, ''),
            COALESCE(counterparty_id, ''),
            COALESCE(trader_id, ''),
            COALESCE(book_id, ''),
            COALESCE(trade_status, '')
        )
    ) AS row_hash
FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD
WHERE trade_id IN (SELECT trade_id FROM validation_sample_ids);

-- 5.4: Compare hashes
SELECT
    COUNT(*)                                         AS total_sampled,
    COUNT(*) FILTER (WHERE s.row_hash = t.row_hash) AS matching_rows,
    COUNT(*) FILTER (WHERE s.row_hash != t.row_hash) AS mismatched_rows,
    COUNT(*) FILTER (WHERE t.trade_id IS NULL)       AS missing_in_target,
    CASE
        WHEN COUNT(*) FILTER (WHERE s.row_hash != t.row_hash) = 0
         AND COUNT(*) FILTER (WHERE t.trade_id IS NULL) = 0
        THEN 'LEVEL5 PASS ✓  All ' || COUNT(*)::VARCHAR || ' sampled rows match'
        ELSE 'LEVEL5 FAIL ✗  Hash or row mismatches detected'
    END AS result
FROM validation_source_hashes s
LEFT JOIN validation_target_hashes t ON s.trade_id = t.trade_id;

-- Cleanup temp tables
DROP TABLE IF EXISTS validation_sample_ids;
DROP TABLE IF EXISTS validation_source_hashes;
DROP TABLE IF EXISTS validation_target_hashes;

-- =============================================================================
-- SUMMARY: VALIDATION SIGN-OFF QUERY
-- Run this as the final gate. All checks must show PASS before dropping source.
-- =============================================================================

SELECT 'Validation complete for partition ' 
    || $VALIDATE_YEAR::VARCHAR || '-' || LPAD($VALIDATE_MONTH::VARCHAR, 2, '0')
    || '. Review all individual PASS/FAIL results above before proceeding.'
    AS sign_off_reminder;

-- =============================================================================
-- END OF SCRIPT 05
-- =============================================================================