-- =============================================================================
-- FILE: sql/02_create_iceberg_tables.sql
-- PURPOSE: Create the Iceberg table schema for warm and cold trade data tiers.
--          Also creates the unified query view used by all downstream consumers.
-- PREREQUISITE: sql/01_setup_external_volume.sql must be run and validated.
-- =============================================================================

USE ROLE ICEBERG_ADMIN;
USE WAREHOUSE TRADE_COLD_WH;
USE DATABASE TRADE_ANALYTICS;
USE SCHEMA TRADE_ANALYTICS.ICEBERG;

-- =============================================================================
-- SECTION 1: TRADES_WARM — Iceberg table for 30-90 day data (~35TB)
-- Partition: (trade_year, trade_month, asset_class)
-- S3 location: s3://tradeco-iceberg-prod/trades_warm/
-- Access pattern: Nightly risk batch queries, recent history lookups
-- =============================================================================

CREATE OR REPLACE ICEBERG TABLE TRADE_ANALYTICS.ICEBERG.TRADES_WARM (

    -- Primary identifiers
    trade_id            VARCHAR(36)     NOT NULL  COMMENT 'UUID — globally unique trade identifier',
    trade_date          DATE            NOT NULL  COMMENT 'Business date of trade execution',
    trade_timestamp     TIMESTAMP_NTZ   NOT NULL  COMMENT 'Exact UTC execution timestamp',
    
    -- Instrument and classification
    asset_class         VARCHAR(50)     NOT NULL  COMMENT 'One of: EQUITY, FX, RATES, CREDIT, COMMODITY, DERIVATIVE, STRUCTURED, CRYPTO, REPO, LOAN, OTHER',
    instrument_id       VARCHAR(20)     NOT NULL  COMMENT 'Internal instrument code (e.g., ISIN or proprietary ID)',
    instrument_name     VARCHAR(200)              COMMENT 'Human-readable instrument name',
    instrument_subtype  VARCHAR(50)               COMMENT 'e.g., VANILLA_OPTION, CDS, IRS, SPOT',
    
    -- Trade economics
    notional_usd        NUMBER(22, 4)   NOT NULL  COMMENT 'USD-equivalent notional value',
    notional_local      NUMBER(22, 4)             COMMENT 'Notional in trade currency',
    local_currency      VARCHAR(3)                COMMENT 'ISO 4217 currency code',
    price               NUMBER(18, 8)             COMMENT 'Execution price',
    quantity            NUMBER(20, 4)             COMMENT 'Units/contracts traded',
    direction           VARCHAR(4)      NOT NULL  COMMENT 'BUY or SELL',
    
    -- Counterparty and book info
    counterparty_id     VARCHAR(20)               COMMENT 'Internal counterparty code',
    counterparty_lei    VARCHAR(20)               COMMENT 'Legal Entity Identifier (for regulatory reporting)',
    trader_id           VARCHAR(20)               COMMENT 'Trader employee ID',
    book_id             VARCHAR(20)               COMMENT 'Trading book identifier',
    desk_id             VARCHAR(20)               COMMENT 'Trading desk identifier',
    entity_id           VARCHAR(20)               COMMENT 'Legal entity that executed the trade',
    
    -- Trade lifecycle
    trade_status        VARCHAR(20)               COMMENT 'CONFIRMED, SETTLED, CANCELLED, AMENDED',
    settlement_date     DATE                      COMMENT 'T+N settlement date',
    value_date          DATE                      COMMENT 'Effective date for FX/rates trades',
    maturity_date       DATE                      COMMENT 'For derivatives and bonds',
    
    -- Regulatory and compliance
    uti                 VARCHAR(52)               COMMENT 'Unique Trade Identifier (CFTC/EMIR)',
    mifid_flag          BOOLEAN                   COMMENT 'TRUE if subject to MiFID II reporting',
    reporting_status    VARCHAR(20)               COMMENT 'REPORTED, PENDING, EXEMPT',
    
    -- Audit columns
    created_at          TIMESTAMP_NTZ   NOT NULL  COMMENT 'Record insertion timestamp',
    updated_at          TIMESTAMP_NTZ             COMMENT 'Last update timestamp',
    source_system       VARCHAR(50)               COMMENT 'Originating system (e.g., MUREX, CALYPSO, SUMMIT)',
    
    -- Materialized partition columns (see ADR-003)
    -- These are explicitly stored because Snowflake Iceberg does not support
    -- partition transforms like year(trade_date) in PARTITION BY as of 2024.
    trade_year          NUMBER(4)       NOT NULL  COMMENT 'YEAR(trade_date) — partition column',
    trade_month         NUMBER(2)       NOT NULL  COMMENT 'MONTH(trade_date) — partition column'
)
PARTITION BY (trade_year, trade_month, asset_class)
CATALOG          = 'SNOWFLAKE'
EXTERNAL_VOLUME  = 'iceberg_prod_vol'
BASE_LOCATION    = 'trades_warm/'
COMMENT          = 'Warm tier: 30-90 day trade data. Partition: year/month/asset_class. Snappy compressed Parquet on S3.'
;

-- =============================================================================
-- SECTION 2: TRADES_COLD — Iceberg table for >90 day data (~450TB)
-- Partition: (trade_year, trade_month, asset_class)
-- S3 location: s3://tradeco-iceberg-prod/trades_cold/
-- Access pattern: Quarterly compliance, annual regulatory reports, ad-hoc analytics
-- =============================================================================

CREATE OR REPLACE ICEBERG TABLE TRADE_ANALYTICS.ICEBERG.TRADES_COLD (

    -- Identical column definitions to TRADES_WARM
    -- (Duplicated here for explicit schema documentation; changes to one table
    --  must be applied to the other. See migration runbook for schema evolution procedure.)

    trade_id            VARCHAR(36)     NOT NULL,
    trade_date          DATE            NOT NULL,
    trade_timestamp     TIMESTAMP_NTZ   NOT NULL,
    asset_class         VARCHAR(50)     NOT NULL,
    instrument_id       VARCHAR(20)     NOT NULL,
    instrument_name     VARCHAR(200),
    instrument_subtype  VARCHAR(50),
    notional_usd        NUMBER(22, 4)   NOT NULL,
    notional_local      NUMBER(22, 4),
    local_currency      VARCHAR(3),
    price               NUMBER(18, 8),
    quantity            NUMBER(20, 4),
    direction           VARCHAR(4)      NOT NULL,
    counterparty_id     VARCHAR(20),
    counterparty_lei    VARCHAR(20),
    trader_id           VARCHAR(20),
    book_id             VARCHAR(20),
    desk_id             VARCHAR(20),
    entity_id           VARCHAR(20),
    trade_status        VARCHAR(20),
    settlement_date     DATE,
    value_date          DATE,
    maturity_date       DATE,
    uti                 VARCHAR(52),
    mifid_flag          BOOLEAN,
    reporting_status    VARCHAR(20),
    created_at          TIMESTAMP_NTZ   NOT NULL,
    updated_at          TIMESTAMP_NTZ,
    source_system       VARCHAR(50),
    trade_year          NUMBER(4)       NOT NULL,
    trade_month         NUMBER(2)       NOT NULL
)
PARTITION BY (trade_year, trade_month, asset_class)
CATALOG          = 'SNOWFLAKE'
EXTERNAL_VOLUME  = 'iceberg_prod_vol'
BASE_LOCATION    = 'trades_cold/'
COMMENT          = 'Cold tier: >90 day trade data. Partition: year/month/asset_class. Snappy Parquet on S3 with Intelligent-Tiering lifecycle.'
;

-- =============================================================================
-- SECTION 3: POST-CREATION VALIDATION
-- Verify tables were created correctly before starting migration.
-- =============================================================================

-- Show Iceberg table properties
SHOW ICEBERG TABLES IN SCHEMA TRADE_ANALYTICS.ICEBERG;

-- Verify external volume linkage and base location
SELECT
    table_name,
    table_schema,
    table_type,
    comment
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'ICEBERG'
  AND TABLE_CATALOG = 'TRADE_ANALYTICS';

-- Verify partition spec was applied correctly (Snowflake metadata)
SELECT
    GET_PATH(PARSE_JSON(SYSTEM$GET_ICEBERG_TABLE_INFORMATION('TRADE_ANALYTICS.ICEBERG.TRADES_COLD')), 'status') AS iceberg_status,
    GET_PATH(PARSE_JSON(SYSTEM$GET_ICEBERG_TABLE_INFORMATION('TRADE_ANALYTICS.ICEBERG.TRADES_COLD')), 'metadataLocation') AS metadata_location
;

-- =============================================================================
-- SECTION 4: UNIFIED QUERY VIEW
-- All downstream tools (Tableau, Python, compliance queries) use this view.
-- Never changes during or after migration — zero-downtime cutover.
-- =============================================================================

USE SCHEMA TRADE_ANALYTICS.VIEWS;

CREATE OR REPLACE VIEW TRADE_ANALYTICS.VIEWS.V_ALL_TRADES
COMMENT = 'Unified trade view spanning all tiers. Query this, not the underlying tables. Update PARTITION_BOUNDARY parameters when promoting data between tiers.'
AS

-- HOT TIER: Snowflake managed table — last 30 days (high-frequency DML, clustering)
SELECT
    trade_id, trade_date, trade_timestamp, asset_class, instrument_id,
    instrument_name, instrument_subtype, notional_usd, notional_local,
    local_currency, price, quantity, direction, counterparty_id,
    counterparty_lei, trader_id, book_id, desk_id, entity_id, trade_status,
    settlement_date, value_date, maturity_date, uti, mifid_flag,
    reporting_status, created_at, updated_at, source_system,
    trade_year, trade_month,
    'HOT'  AS data_tier
FROM TRADE_ANALYTICS.MANAGED.TRADES_HOT

UNION ALL

-- WARM TIER: Iceberg on S3 — 30-90 days
SELECT
    trade_id, trade_date, trade_timestamp, asset_class, instrument_id,
    instrument_name, instrument_subtype, notional_usd, notional_local,
    local_currency, price, quantity, direction, counterparty_id,
    counterparty_lei, trader_id, book_id, desk_id, entity_id, trade_status,
    settlement_date, value_date, maturity_date, uti, mifid_flag,
    reporting_status, created_at, updated_at, source_system,
    trade_year, trade_month,
    'WARM' AS data_tier
FROM TRADE_ANALYTICS.ICEBERG.TRADES_WARM

UNION ALL

-- COLD TIER: Iceberg on S3 — >90 days
SELECT
    trade_id, trade_date, trade_timestamp, asset_class, instrument_id,
    instrument_name, instrument_subtype, notional_usd, notional_local,
    local_currency, price, quantity, direction, counterparty_id,
    counterparty_lei, trader_id, book_id, desk_id, entity_id, trade_status,
    settlement_date, value_date, maturity_date, uti, mifid_flag,
    reporting_status, created_at, updated_at, source_system,
    trade_year, trade_month,
    'COLD' AS data_tier
FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD
;

-- Grant read access on the view
GRANT SELECT ON VIEW TRADE_ANALYTICS.VIEWS.V_ALL_TRADES TO ROLE ICEBERG_READER;

-- =============================================================================
-- SECTION 5: DATA LIFECYCLE PROMOTION PROCEDURE
-- Runs daily at 02:00 UTC to promote data from hot → warm → cold
-- =============================================================================

CREATE OR REPLACE PROCEDURE TRADE_ANALYTICS.VIEWS.SP_PROMOTE_DATA_TIERS()
RETURNS TABLE (tier VARCHAR, rows_promoted NUMBER, status VARCHAR)
LANGUAGE SQL
AS
$$
DECLARE
    hot_to_warm_rows  NUMBER DEFAULT 0;
    warm_to_cold_rows  NUMBER DEFAULT 0;
    cutoff_hot_to_warm DATE;
    cutoff_warm_to_cold DATE;
BEGIN
    cutoff_hot_to_warm  := DATEADD('day', -30, CURRENT_DATE());
    cutoff_warm_to_cold := DATEADD('day', -90, CURRENT_DATE());

    -- STEP 1: Promote hot → warm (data older than 30 days)
    -- STEP 1: Promote hot → warm (data older than 30 days)
    -- NOT EXISTS check prevents duplicate inserts if task runs twice
    INSERT INTO TRADE_ANALYTICS.ICEBERG.TRADES_WARM
    SELECT
        trade_id, trade_date, trade_timestamp, asset_class, instrument_id,
        instrument_name, instrument_subtype, notional_usd, notional_local,
        local_currency, price, quantity, direction, counterparty_id,
        counterparty_lei, trader_id, book_id, desk_id, entity_id, trade_status,
        settlement_date, value_date, maturity_date, uti, mifid_flag,
        reporting_status, created_at, updated_at, source_system,
        trade_year, trade_month
    FROM TRADE_ANALYTICS.MANAGED.TRADES_HOT src
    WHERE src.trade_date < :cutoff_hot_to_warm
      AND NOT EXISTS (
          SELECT 1
          FROM TRADE_ANALYTICS.ICEBERG.TRADES_WARM tgt
          WHERE tgt.trade_id    = src.trade_id
            AND tgt.trade_year  = YEAR(src.trade_date)
            AND tgt.trade_month = MONTH(src.trade_date)
      );

    hot_to_warm_rows := SQLROWCOUNT;

    -- STEP 2: Promote warm → cold (data older than 90 days)
    INSERT INTO TRADE_ANALYTICS.ICEBERG.TRADES_COLD
    SELECT
        trade_id, trade_date, trade_timestamp, asset_class, instrument_id,
        instrument_name, instrument_subtype, notional_usd, notional_local,
        local_currency, price, quantity, direction, counterparty_id,
        counterparty_lei, trader_id, book_id, desk_id, entity_id, trade_status,
        settlement_date, value_date, maturity_date, uti, mifid_flag,
        reporting_status, created_at, updated_at, source_system,
        trade_year, trade_month
    FROM TRADE_ANALYTICS.ICEBERG.TRADES_WARM src
    WHERE src.trade_date < :cutoff_warm_to_cold
      AND NOT EXISTS (
          SELECT 1
          FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD tgt
          WHERE tgt.trade_id    = src.trade_id
            AND tgt.trade_year  = YEAR(src.trade_date)
            AND tgt.trade_month = MONTH(src.trade_date)
      );

    warm_to_cold_rows := SQLROWCOUNT;

    -- STEP 3: Delete promoted records from source tiers
    -- Only after both inserts succeed (sequential, not transactional across Iceberg)
    DELETE FROM TRADE_ANALYTICS.MANAGED.TRADES_HOT
    WHERE trade_date < :cutoff_hot_to_warm;

    DELETE FROM TRADE_ANALYTICS.ICEBERG.TRADES_WARM
    WHERE trade_date < :cutoff_warm_to_cold;

    RETURN TABLE (
        SELECT 'HOT→WARM' AS tier, :hot_to_warm_rows AS rows_promoted, 'SUCCESS' AS status
        UNION ALL
        SELECT 'WARM→COLD', :warm_to_cold_rows, 'SUCCESS'
    );
END;
$$;

-- Schedule the promotion procedure
CREATE OR REPLACE TASK TRADE_ANALYTICS.VIEWS.TASK_DAILY_TIER_PROMOTION
    WAREHOUSE = TRADE_HOT_WH
    SCHEDULE  = 'USING CRON 0 2 * * * UTC'
    COMMENT   = 'Daily data tier promotion: hot→warm→cold at 02:00 UTC'
AS
CALL TRADE_ANALYTICS.VIEWS.SP_PROMOTE_DATA_TIERS();

-- Resume the task (tasks start in SUSPENDED state)
ALTER TASK TRADE_ANALYTICS.VIEWS.TASK_DAILY_TIER_PROMOTION RESUME;

-- =============================================================================
-- SECTION 6: MONTHLY COMPLIANCE SNAPSHOT PROCEDURE
-- Creates a managed-table clone of trades_cold on the 1st of each month.
-- Compliance team uses these for AT (TIMESTAMP => ...) Time Travel queries.
-- Iceberg tables do not support Snowflake Time Travel syntax — see ADR-002.
-- Snapshots are retained for 13 months then auto-dropped.
-- =============================================================================

CREATE OR REPLACE PROCEDURE TRADE_ANALYTICS.SNAPSHOTS.SP_MONTHLY_SNAPSHOT()
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    snap_name   STRING;
    drop_name   STRING;
    snap_month  STRING;
    drop_month  STRING;
BEGIN
    -- Name for this month's new snapshot (previous month's data)
    snap_month := TO_CHAR(DATEADD('month', -1, CURRENT_DATE()), 'YYYYMM');
    snap_name  := 'TRADE_ANALYTICS.SNAPSHOTS.TRADES_COLD_SNAP_' || snap_month;

    -- Name of the snapshot to drop (13 months old — beyond retention window)
    drop_month := TO_CHAR(DATEADD('month', -14, CURRENT_DATE()), 'YYYYMM');
    drop_name  := 'TRADE_ANALYTICS.SNAPSHOTS.TRADES_COLD_SNAP_' || drop_month;

    -- Create new snapshot (zero-copy clone of Iceberg table as managed table)
    -- The clone is a managed table — supports Snowflake Time Travel syntax.
    EXECUTE IMMEDIATE
        'CREATE OR REPLACE TABLE ' || snap_name ||
        ' CLONE TRADE_ANALYTICS.ICEBERG.TRADES_COLD';

    -- Drop the 14-month-old snapshot (13-month retention policy)
    EXECUTE IMMEDIATE
        'DROP TABLE IF EXISTS ' || drop_name;

    RETURN 'Created: ' || snap_name || ' | Dropped: ' || drop_name;
END;
$$;

-- Schedule: runs on the 1st of every month at 03:00 UTC
CREATE OR REPLACE TASK TRADE_ANALYTICS.SNAPSHOTS.TASK_MONTHLY_SNAPSHOT
    WAREHOUSE = ANALYST_WH
    SCHEDULE  = 'USING CRON 0 3 1 * * UTC'
    COMMENT   = 'Monthly compliance snapshot — clones trades_cold as managed table for Time Travel support'
AS
CALL TRADE_ANALYTICS.SNAPSHOTS.SP_MONTHLY_SNAPSHOT();

-- Resume task (tasks start SUSPENDED by default)
ALTER TASK TRADE_ANALYTICS.SNAPSHOTS.TASK_MONTHLY_SNAPSHOT RESUME;

-- Grant execute to compliance role
GRANT USAGE ON PROCEDURE TRADE_ANALYTICS.SNAPSHOTS.SP_MONTHLY_SNAPSHOT()
    TO ROLE ICEBERG_READER;

-- =============================================================================
-- END OF SCRIPT 02
-- NEXT: Run sql/03_migrate_data.sql
-- =============================================================================