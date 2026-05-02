-- =============================================================================
-- FILE: sql/04_performance_benchmarks.sql
-- PURPOSE: Benchmark suite comparing query performance on managed tables vs
--          Iceberg tables. Run BEFORE and AFTER migration to produce the
--          comparison numbers in README.md.
--
-- METHODOLOGY:
--   - All benchmarks run on XSMALL warehouse (2 credits/hour)
--   - 3 cold runs per query (cache cleared between runs via ALTER SESSION)
--   - Results measured from QUERY_HISTORY, not wall clock
--   - Same physical data volume in both managed and Iceberg tables
--   - Test dataset: Full year 2022 (calibrated to ~80TB after Parquet compression)
--
-- INTERPRETATION GUIDANCE:
--   Iceberg is expected to be FASTER on partition-aligned queries.
--   Iceberg is expected to be SLOWER on non-partition-key point lookups.
--   Both behaviors are documented in README.md benchmarks table.
-- =============================================================================

USE ROLE ICEBERG_READER;
USE WAREHOUSE ANALYST_WH;
USE DATABASE TRADE_ANALYTICS;

-- =============================================================================
-- SETUP: Cache control
-- =============================================================================

-- Clear result cache between benchmark runs
ALTER SESSION SET USE_CACHED_RESULT = FALSE;

-- Suspend and resume warehouse to clear data cache (run between cold-run sets)
-- ALTER WAREHOUSE ANALYST_WH SUSPEND;
-- ALTER WAREHOUSE ANALYST_WH RESUME;

-- =============================================================================
-- BENCHMARK 1: Full year scan, single asset class
-- Pattern: Compliance report — FX trades for all of 2022
-- Expected: Iceberg MUCH faster (partition pruning eliminates 10/11 asset classes)
-- =============================================================================

-- 1A: Managed table baseline
SELECT
    trade_date,
    SUM(notional_usd)   AS total_notional,
    COUNT(*)            AS trade_count,
    AVG(price)          AS avg_price,
    COUNT(DISTINCT counterparty_id) AS unique_counterparties
FROM TRADE_ANALYTICS.MANAGED.TRADES_COLD_LEGACY
WHERE trade_date BETWEEN '2022-01-01' AND '2022-12-31'
  AND asset_class = 'FX'
GROUP BY trade_date
ORDER BY trade_date;

-- 1B: Iceberg table
SELECT
    trade_date,
    SUM(notional_usd)   AS total_notional,
    COUNT(*)            AS trade_count,
    AVG(price)          AS avg_price,
    COUNT(DISTINCT counterparty_id) AS unique_counterparties
FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD
WHERE trade_year  = 2022
  AND asset_class = 'FX'
GROUP BY trade_date
ORDER BY trade_date;

-- NOTE: On Iceberg, filter on trade_year (partition column) enables partition
-- pruning. The query touches only trade_year=2022/asset_class=FX partitions.
-- On managed tables, Snowflake uses micro-partition pruning on trade_date,
-- but still scans all asset classes until they're eliminated by filtering.

-- =============================================================================
-- BENCHMARK 2: Point lookup by trade_id
-- Pattern: Compliance investigation — find a specific trade
-- Expected: Iceberg SLOWER (trade_id is not a partition column; full partition scan)
-- =============================================================================

-- 2A: Managed table (micro-partition clustering often includes trade_id range)
SELECT *
FROM TRADE_ANALYTICS.MANAGED.TRADES_COLD_LEGACY
WHERE trade_id = '550e8400-e29b-41d4-a716-446655440000';

-- 2B: Iceberg table (must scan partition-by-partition to find the row)
SELECT *
FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD
WHERE trade_id = '550e8400-e29b-41d4-a716-446655440000';

-- WORKAROUND for Iceberg point lookups: if trade_date is known, add it to filter
SELECT *
FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD
WHERE trade_id    = '550e8400-e29b-41d4-a716-446655440000'
  AND trade_year  = 2022
  AND trade_month = 6;
-- With partition context: performance approaches managed table speed

-- =============================================================================
-- BENCHMARK 3: Monthly aggregation by book
-- Pattern: Risk batch — book P&L for last month
-- Expected: Iceberg faster (one month = one partition slice)
-- =============================================================================

-- 3A: Managed table
SELECT
    book_id,
    asset_class,
    direction,
    SUM(notional_usd)       AS gross_notional,
    COUNT(*)                AS trade_count,
    MIN(trade_timestamp)    AS first_trade,
    MAX(trade_timestamp)    AS last_trade
FROM TRADE_ANALYTICS.MANAGED.TRADES_COLD_LEGACY
WHERE trade_date BETWEEN '2022-06-01' AND '2022-06-30'
GROUP BY book_id, asset_class, direction
ORDER BY gross_notional DESC;

-- 3B: Iceberg table
SELECT
    book_id,
    asset_class,
    direction,
    SUM(notional_usd)       AS gross_notional,
    COUNT(*)                AS trade_count,
    MIN(trade_timestamp)    AS first_trade,
    MAX(trade_timestamp)    AS last_trade
FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD
WHERE trade_year  = 2022
  AND trade_month = 6
GROUP BY book_id, asset_class, direction
ORDER BY gross_notional DESC;

-- =============================================================================
-- BENCHMARK 4: Cross-year range scan (3 years, all asset classes)
-- Pattern: Annual regulatory report — 3-year aggregate
-- Expected: Iceberg substantially faster (partitions allow year-level pruning)
-- =============================================================================

-- 4A: Managed table
SELECT
    YEAR(trade_date)    AS year,
    asset_class,
    entity_id,
    COUNT(*)            AS trade_count,
    SUM(notional_usd)   AS total_notional,
    COUNT(DISTINCT uti) AS uti_count
FROM TRADE_ANALYTICS.MANAGED.TRADES_COLD_LEGACY
WHERE trade_date BETWEEN '2020-01-01' AND '2022-12-31'
  AND mifid_flag = TRUE
GROUP BY YEAR(trade_date), asset_class, entity_id
ORDER BY year, asset_class, entity_id;

-- 4B: Iceberg table
SELECT
    trade_year,
    asset_class,
    entity_id,
    COUNT(*)            AS trade_count,
    SUM(notional_usd)   AS total_notional,
    COUNT(DISTINCT uti) AS uti_count
FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD
WHERE trade_year BETWEEN 2020 AND 2022
  AND mifid_flag = TRUE
GROUP BY trade_year, asset_class, entity_id
ORDER BY trade_year, asset_class, entity_id;

-- =============================================================================
-- BENCHMARK 5: Counterparty lookup (high-cardinality non-partition column)
-- Pattern: Risk — latest 1000 trades for a given counterparty
-- Expected: Iceberg SLOWER (counterparty_id has ~20K distinct values, not partitioned)
-- =============================================================================

-- 5A: Managed table
SELECT TOP 1000
    trade_id,
    trade_date,
    asset_class,
    notional_usd,
    trade_status
FROM TRADE_ANALYTICS.MANAGED.TRADES_COLD_LEGACY
WHERE counterparty_id = 'CP_001234'
ORDER BY trade_timestamp DESC;

-- 5B: Iceberg table
SELECT
    trade_id,
    trade_date,
    asset_class,
    notional_usd,
    trade_status
FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD
WHERE counterparty_id = 'CP_001234'
ORDER BY trade_timestamp DESC
LIMIT 1000;

-- =============================================================================
-- RESULTS EXTRACTION
-- After running all benchmarks, pull execution stats from QUERY_HISTORY
-- =============================================================================

-- Get benchmark results with execution metrics
-- (Run after completing all benchmark queries above)
SELECT
    query_text,
    total_elapsed_time / 1000.0       AS elapsed_seconds,
    bytes_scanned / (1024*1024*1024.0) AS gb_scanned,
    partitions_scanned,
    partitions_total,
    ROUND(100 * (1 - partitions_scanned::FLOAT / NULLIF(partitions_total, 0)), 1)
                                       AS pct_partitions_pruned,
    bytes_spilled_to_local_storage,
    credits_used_cloud_services
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY(
    DATE_RANGE_START => DATEADD('hour', -2, CURRENT_TIMESTAMP()),
    RESULT_LIMIT     => 50
))
WHERE query_type = 'SELECT'
  AND execution_status = 'SUCCESS'
  AND database_name = 'TRADE_ANALYTICS'
ORDER BY start_time DESC;

-- =============================================================================
-- STORAGE FOOTPRINT COMPARISON (run after migration is complete)
-- =============================================================================

-- Managed table storage
SELECT
    TABLE_CATALOG,
    TABLE_SCHEMA,
    TABLE_NAME,
    ROUND(ACTIVE_BYTES / (1024*1024*1024*1024.0), 2)           AS active_tb,
    ROUND(TIME_TRAVEL_BYTES / (1024*1024*1024*1024.0), 2)      AS time_travel_tb,
    ROUND(FAILSAFE_BYTES / (1024*1024*1024*1024.0), 2)         AS failsafe_tb,
    ROUND((ACTIVE_BYTES + TIME_TRAVEL_BYTES + FAILSAFE_BYTES) 
          / (1024*1024*1024*1024.0), 2)                        AS total_billed_tb
FROM INFORMATION_SCHEMA.TABLE_STORAGE_METRICS
WHERE TABLE_SCHEMA = 'MANAGED'
  AND TABLE_CATALOG = 'TRADE_ANALYTICS'
ORDER BY total_billed_tb DESC;

-- Iceberg table storage (S3 footprint — active data only, no TT/FS overhead)
SELECT
    TABLE_CATALOG,
    TABLE_SCHEMA,
    TABLE_NAME,
    ROUND(ACTIVE_BYTES / (1024*1024*1024*1024.0), 2) AS active_tb,
    TIME_TRAVEL_BYTES    AS time_travel_tb,   -- Will be 0 for Iceberg
    FAILSAFE_BYTES       AS failsafe_tb        -- Will be 0 for Iceberg
FROM INFORMATION_SCHEMA.TABLE_STORAGE_METRICS
WHERE TABLE_SCHEMA = 'ICEBERG'
  AND TABLE_CATALOG = 'TRADE_ANALYTICS'
ORDER BY active_tb DESC;

-- =============================================================================
-- END OF SCRIPT 04
-- =============================================================================