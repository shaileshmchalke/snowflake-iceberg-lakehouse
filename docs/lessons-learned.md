# Lessons Learned: Post-Migration Retrospective

## Overview

This document covers the four significant failures encountered during the migration, root cause analysis, fixes applied, and rules derived for future projects. Written 30 days post-production cutover.

---

## Failure 1: Partition Over-Engineering — The Metadata Explosion

### Timeline

- **Week 4:** Initial Iceberg tables created with partition spec `(trade_year, trade_month, asset_class, book_id)`
- **Week 5:** First 6 months of data migrated (~75TB)
- **Week 6:** Query planning time measured at 45–62 seconds on a MEDIUM warehouse. Queries that should have taken 8–12 seconds were unusable.
- **Week 6 (Day 3):** Root cause identified via `SYSTEM$CLUSTERING_INFORMATION` and Iceberg metadata inspection

### Root Cause

Apache Iceberg maintains a partition manifest that lists every distinct partition and the data files within it. With `book_id` (4,200 distinct values) as the innermost partition column:

```
partition_count = years × months × asset_classes × book_ids
               = 3 × 12 × 11 × 4,200
               = 1,663,200 partition entries
```

Snowflake must read and evaluate ALL partition manifest entries before it can determine which files to read. At 1.6 million entries, manifest scan time dominated total query time — before any Parquet file was opened.

The mistake: confusing "I want to filter on book_id" with "book_id should be a partition column." Filtering is served by column statistics within Parquet files (min/max bloom filters), NOT by partition metadata. You only need a column in the partition spec if partition-level pruning provides substantial benefit AND cardinality is bounded.

### Fix

1. Dropped all partition entries (no ALTER PARTITION support at the time — required table rebuild)
2. Re-created table with `(trade_year, trade_month, asset_class)` — 396 partition entries total
3. Re-migrated the 75TB that had already been moved (added 2 weeks to timeline)
4. Added `book_id` to the **clustering** config within each partition using `CLUSTER BY` on the managed table equivalent

### Time Lost

2 weeks of re-migration + 3 days of diagnosis = **~2.5 weeks**

### Rules Derived

```
Rule 1: Partition column cardinality should be in range [2, 1000].
        Above 1000 → use column-level statistics and file pruning.
        Below 2    → partition adds overhead without benefit.

Rule 2: Before committing a partition strategy, calculate:
        total_partitions = product(distinct_values_per_partition_column)
        If total_partitions > 50,000 → redesign.

Rule 3: Query patterns that filter on high-cardinality columns (IDs, codes)
        are better served by:
        (a) Sorting data by that column within each partition file
        (b) Parquet row-group statistics (min/max per column)
        (c) Search optimization service on managed tables
        NOT by adding that column to the partition spec.
```

---

## Failure 2: Snowflake Time Travel Does Not Work on Iceberg Tables

### Timeline

- **Week 11:** Production cutover complete for TRADES_COLD
- **Week 12:** Compliance team attempts standard quarterly point-in-time query
- **Week 12 (same day):** Query fails with unexpected error

### Failing Query

```sql
-- Query run by compliance analyst (standard pattern they've used for 3 years)
SELECT
    trade_id,
    notional_usd,
    trade_status
FROM trade_analytics.v_all_trades
AT (TIMESTAMP => '2024-01-15 08:00:00')
WHERE trade_date BETWEEN '2023-01-01' AND '2023-12-31'
  AND asset_class = 'FX';
-- Error: Time Travel is not supported for Iceberg tables.
```

### Root Cause

Snowflake's `AT (TIMESTAMP => ...)` and `BEFORE (STATEMENT => ...)` Time Travel syntax is a Snowflake-proprietary feature that works by reading micro-partition historical versions stored in Snowflake's internal storage layer. Iceberg tables store data in S3 using the Iceberg snapshot model — a different mechanism with different APIs.

As of early 2024, Snowflake does NOT expose Iceberg's native snapshot-based time travel through the standard Snowflake SQL Time Travel interface. To access a historical Iceberg snapshot, you need the snapshot ID, which is only accessible programmatically.

This was a known limitation documented in Snowflake's release notes — but not in any of the sales or pre-sales materials reviewed during project scoping.

### Impact

The compliance team runs 14 distinct point-in-time queries per quarter. All 14 were broken after cutover.

### Fix

Two-part solution:

**Part A — Monthly Snapshot Tables (immediate fix):**

```sql
-- Stored procedure run on the 1st of each month
-- Creates a point-in-time snapshot of the Iceberg table as a managed table
-- Retained for 13 months (covers all quarterly lookback windows)

CREATE OR REPLACE PROCEDURE trade_analytics.sp_snapshot_iceberg_monthly()
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    snap_table_name STRING;
    snap_date STRING;
BEGIN
    snap_date := TO_CHAR(DATEADD('month', -1, CURRENT_DATE()), 'YYYYMM');
    snap_table_name := 'trade_analytics.trades_cold_snap_' || snap_date;
    
    EXECUTE IMMEDIATE 
        'CREATE TABLE ' || snap_table_name || 
        ' CLONE trade_analytics.trades_cold';

    RETURN 'Snapshot created: ' || snap_table_name;
END;
$$;

-- Schedule via Snowflake Tasks
CREATE OR REPLACE TASK trade_analytics.task_monthly_iceberg_snapshot
    WAREHOUSE = XSMALL_WH
    SCHEDULE  = 'USING CRON 0 3 1 * * UTC'
AS
CALL trade_analytics.sp_snapshot_iceberg_monthly();
```

> **Important:** `CLONE` of an Iceberg table creates a managed table copy. This is intentional — the managed clone supports Time Travel. The storage cost of the clone is covered by the savings from the migration.

**Part B — Updated compliance query pattern:**

```sql
-- Compliance now queries snapshot tables directly for point-in-time needs
-- Naming convention: trades_cold_snap_YYYYMM (as-of end-of-month state)

SELECT
    trade_id,
    notional_usd,
    trade_status
FROM trade_analytics.trades_cold_snap_202301  -- Jan 2023 snapshot
WHERE trade_date BETWEEN '2023-01-01' AND '2023-12-31'
  AND asset_class = 'FX';
```

### Rules Derived

```
Rule 4: For ANY Snowflake feature you depend on, explicitly test it 
        against Iceberg tables in a non-production environment BEFORE
        committing to migration. The feature matrix for Iceberg vs.
        managed tables is NOT the same.

Rule 5: Features to explicitly test before migrating:
        - Time Travel (AT / BEFORE)
        - CLONE
        - UNDROP
        - SEARCH OPTIMIZATION
        - DYNAMIC TABLES
        - STREAMS (Change Data Capture)
        Note: As of 2024, STREAMS on Iceberg tables have limited support.
        Check current Snowflake release notes.

Rule 6: Map every downstream consumer's query patterns BEFORE migration.
        Don't rely on "it's just SELECT queries." Time travel, CDC streams,
        and dynamic tables are features that hide in production usage.
```

---

## Failure 3: IAM Trust Policy Race Condition in Multi-Account AWS

### Timeline

- **Week 1:** External volume DDL runs successfully (no error)
- **Week 2:** First test INSERT into Iceberg table
- **Week 2 (same day):** Cryptic `Access Denied` error

### Error Message (Actual)

```
SQL compilation error:
External volume 'ICEBERG_PROD_VOL' is not accessible. 
Check that the storage location exists and your external volume 
has the correct permissions. Storage provider message: 
Access Denied (Status Code: 403; Error Code: AccessDenied)
```

### Diagnosis Path

This error message is deceptive. "Access Denied" suggests an S3 bucket policy problem. We spent 2 days reviewing S3 bucket policies. They were correct.

The real issue emerged from AWS CloudTrail (which we had to manually enable on the data account — it was off by default):

```
CloudTrail Event: AssumeRole
  Requestor: arn:aws:iam::111111111111:role/snowflake-iceberg-role (Account B - platform account)
  Target:    arn:aws:iam::222222222222:role/s3-data-access-role    (Account A - data account)
  Result:    AccessDenied
  Reason:    The role trust policy does not allow cross-account assumption 
             from the Snowflake IAM principal in Account B.
```

### Root Cause (Detailed)

The AWS architecture:

```
Snowflake's IAM Principal 
(arn:aws:iam::SNOWFLAKE_ACCT:user/snowflake-user-xyz)
    │
    │ AssumeRole
    ▼
IAM Role in Account B (Platform Account)  ← We created this
(arn:aws:iam::111111111111:role/snowflake-iceberg-role)
    │
    │ AssumeRole (cross-account)
    ▼
IAM Role in Account A (Data Account)      ← This is where S3 bucket is
(arn:aws:iam::222222222222:role/s3-data-access-role)
    │
    │ s3:GetObject, s3:PutObject
    ▼
S3 Bucket: tradeco-iceberg-prod (Account A)
```

The problem: Snowflake external volume only supports **one hop** in the assume-role chain. Snowflake's IAM user assumes a role, and that role must have direct S3 access. A two-hop chain (Account B role → Account A role) is not supported.

### Fix

Moved the IAM role to Account A (same account as the S3 bucket):

```
Snowflake IAM Principal 
(arn:aws:iam::SNOWFLAKE_ACCT:user/snowflake-user-xyz)
    │
    │ AssumeRole (direct)
    ▼
IAM Role in Account A (Data Account)  ← Role must live here
(arn:aws:iam::222222222222:role/snowflake-iceberg-role)
    │
    │ s3:GetObject, s3:PutObject (same account — simple)
    ▼
S3 Bucket: tradeco-iceberg-prod (Account A)
```

Updated Terraform: see `config/terraform/main.tf` — the `aws_iam_role` resource is defined in the data account provider, not the platform account provider.

### Rules Derived

```
Rule 7: Snowflake external volume → S3 access is a single-hop assume-role.
        The IAM role Snowflake assumes MUST have direct S3 permissions.
        Cross-account role chaining is not supported.
        
Rule 8: The IAM role must live in the SAME AWS account as the S3 bucket.
        If your org uses account separation (data account vs platform account),
        the role goes in the data account.

Rule 9: Enable AWS CloudTrail on the data account BEFORE starting Snowflake
        external volume configuration. S3 access errors that root-cause in STS
        are invisible without CloudTrail. Every hour of CloudTrail = $0.10.
        Every hour of debugging without it = much more.

Rule 10: Test the external volume with a DESCRIBE + a simple PUT before 
         building any Iceberg table structure:
         
         -- After DESCRIBE EXTERNAL VOLUME, run:
         CREATE STAGE iceberg_test_stage
           EXTERNAL_VOLUME = 'iceberg_prod_vol'
           DIRECTORY = (ENABLE = TRUE);
         -- If this fails, fix IAM before proceeding. 
         -- Do not create Iceberg tables until this passes.
```

### Time Lost

6 days (2 days on S3 policy, 1 day enabling CloudTrail, 1 day on STS diagnosis, 1 day on Terraform fix and re-apply, 1 day re-testing).

---

## Failure 4: DML Concurrency During Migration Window

### Timeline

- **Week 5:** Migrating October 2022 partition (~12TB, ~200M rows)
- **Week 5 (during migration):** Upstream ETL job runs, writes ~15,000 new rows to managed table
- **Week 5 (post-migration):** Row count validation fails by 15,000 rows

### Root Cause

The migration query was:
```sql
INSERT INTO trades_cold
SELECT ... FROM trades_managed WHERE trade_date BETWEEN '2022-10-01' AND '2022-10-31';
```

While this INSERT was running (~40 minutes), an upstream reconciliation ETL inserted 15,000 late-arriving records into `trades_managed` for October 2022 (T+30 reconciliation inserts back-dated records). The INSERT INTO trades_cold completed successfully with the count at the start of the job. The validation check ran against the managed table's count AFTER the ETL had run.

Result: Row count delta = 15,000. Validation failed. We re-ran the full month's migration assuming data corruption — wasted 40 minutes + 8 credits.

### Fix

**Snapshot-first migration pattern:**

```sql
-- Step 1: Create a zero-copy clone of the source data for this partition
CREATE OR REPLACE TABLE trade_analytics.trades_managed_snap_202210
  CLONE trade_analytics.trades_managed
  BEFORE (STATEMENT => LAST_QUERY_ID());
  -- Or simply: CLONE at current moment before any upstream ETL runs

-- Step 2: Migrate from the clone (immutable, no concurrent writes)
INSERT INTO trade_analytics.trades_cold
SELECT ... FROM trade_analytics.trades_managed_snap_202210;

-- Step 3: Validate against the clone (not the live table)
SELECT COUNT(*) FROM trade_analytics.trades_managed_snap_202210;
-- Compare to: SELECT COUNT(*) FROM trade_analytics.trades_cold WHERE trade_year=2022 AND trade_month=10;

-- Step 4: Drop clone
DROP TABLE trade_analytics.trades_managed_snap_202210;
```

This pattern is in `scripts/migrate_table.sh` — each month's migration uses a clone as source.

### Rules Derived

```
Rule 11: Never validate a migration by comparing to the LIVE source table.
         Always validate against the SOURCE SNAPSHOT used for migration.
         Live tables change. Snapshots don't.

Rule 12: For any table with concurrent upstream writes, use CLONE as the
         migration source. CLONE is zero-copy in Snowflake — it costs 
         nothing until the cloned data diverges from the original.
         
Rule 13: Know your upstream write patterns. "Historical data" is often not
         as immutable as it sounds. T+1, T+2, T+30 reconciliation processes
         frequently back-write into historical partitions.
```

---

## Summary of Rules

| # | Rule |
|---|---|
| 1 | Partition cardinality must be between 2 and ~1,000 per column |
| 2 | Calculate `total_partitions` before committing partition spec. >50K → redesign |
| 3 | High-cardinality columns → column stats/sorting, NOT partitioning |
| 4 | Test every Snowflake feature against Iceberg tables specifically before migrating |
| 5 | Explicitly test: Time Travel, CLONE, UNDROP, Search Optimization, Streams |
| 6 | Map ALL downstream query patterns before migration, including compliance queries |
| 7 | External volume → S3 is a single-hop assume-role, no chaining |
| 8 | IAM role must live in the same AWS account as the S3 bucket |
| 9 | Enable CloudTrail on data account BEFORE starting external volume setup |
| 10 | Test external volume with a simple stage operation before creating Iceberg tables |
| 11 | Validate against migration source snapshot, not live source table |
| 12 | Use CLONE as migration source for any table with concurrent writes |
| 13 | Audit upstream write patterns — "historical" ≠ "immutable" |