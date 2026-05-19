-- =============================================================================
-- FILE: sql/00_prerequisites_check.sql
-- PURPOSE: Pre-flight validation. Run this FIRST before any other SQL script.
-- EXPECTED: All checks show PASS before proceeding to script 01.
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- CHECK 1: Snowflake Edition supports Iceberg (Enterprise required)
SELECT
    CURRENT_ACCOUNT()   AS account_name,
    CURRENT_REGION()    AS region,
    CURRENT_VERSION()   AS sf_version,
    CASE
        WHEN CURRENT_ORGANIZATION_NAME() IS NOT NULL
        THEN 'CHECK-1 PASS ✓  Run SHOW PARAMETERS to verify Enterprise edition'
        ELSE 'CHECK-1 WARN ⚠️  Verify your edition supports Iceberg tables'
    END AS edition_check;

-- CHECK 2: Required warehouses exist
SELECT
    name            AS warehouse_name,
    size,
    auto_resume,
    CASE
        WHEN auto_resume = 'true'
        THEN 'CHECK-2 PASS ✓  ' || name || ' exists and auto-resumes'
        ELSE 'CHECK-2 WARN ⚠️  ' || name || ' — enable auto_resume'
    END AS warehouse_check
FROM INFORMATION_SCHEMA.WAREHOUSES
WHERE name IN (
    'TRADE_HOT_WH', 'TRADE_COLD_WH', 'MIGRATION_WH', 'ANALYST_WH'
)
ORDER BY name;
-- Expected: 4 rows. If fewer → run 01_setup_external_volume.sql first.

-- CHECK 3: Required schemas exist
SELECT
    schema_name,
    'CHECK-3 PASS ✓  Schema exists: ' || schema_name AS schema_check
FROM INFORMATION_SCHEMA.SCHEMATA
WHERE catalog_name = 'TRADE_ANALYTICS'
  AND schema_name IN ('MANAGED', 'ICEBERG', 'VIEWS', 'SNAPSHOTS', 'RAW')
ORDER BY schema_name;
-- Expected: 5 rows.

-- CHECK 4: Source managed table exists and has data
USE ROLE MIGRATION_ROLE;
USE WAREHOUSE ANALYST_WH;

SELECT
    COUNT(*)                    AS total_rows,
    MIN(trade_date)             AS earliest_date,
    MAX(trade_date)             AS latest_date,
    DATEDIFF('month',
        MIN(trade_date),
        MAX(trade_date)) + 1    AS months_to_migrate,
    CASE
        WHEN COUNT(*) > 0
        THEN 'CHECK-4 PASS ✓  Source table has data'
        ELSE 'CHECK-4 FAIL ✗  Source table is empty — check table name'
    END AS source_check
FROM TRADE_ANALYTICS.MANAGED.TRADES_COLD_LEGACY;

-- CHECK 5: No duplicate trade_id in source (duplicates break validation)
SELECT
    CASE
        WHEN COUNT(*) = COUNT(DISTINCT trade_id)
        THEN 'CHECK-5 PASS ✓  No duplicate trade_id'
        ELSE 'CHECK-5 FAIL ✗  Duplicates: ' ||
             (COUNT(*) - COUNT(DISTINCT trade_id))::VARCHAR ||
             ' — fix before migrating'
    END AS duplicate_check
FROM TRADE_ANALYTICS.MANAGED.TRADES_COLD_LEGACY;

-- SUMMARY
SELECT '✅ Review all checks above. Fix every FAIL before running script 01.'
    AS next_step;