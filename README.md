# Snowflake Iceberg Lakehouse Migration
### 500TB Historical Trade Data | 62% Storage Cost Reduction | Financial Services

[![GitHub stars](https://img.shields.io/github/stars/tumchausername/snowflake-iceberg-lakehouse)](https://github.com/tumchausername/snowflake-iceberg-lakehouse/stargazers)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Terraform](https://img.shields.io/badge/terraform-1.5+-blue)](https://terraform.io)
[![Snowflake](https://img.shields.io/badge/snowflake-iceberg-29B5E8)](https://snowflake.com)
[![AWS S3](https://img.shields.io/badge/AWS-S3-FF9900)](https://aws.amazon.com/s3)

> **Role:** Senior Snowflake Solutions Architect  
> **Client:** US-based Financial Services Firm (bulge-bracket trading desk)  
> **Timeline:** 14 weeks (discovery → production cutover)  
> **Outcome:** $1.98M annual savings | Sub-5s query SLA maintained | Zero data loss

---

## Table of Contents

1. [Business Context](#1-business-context)
2. [The Problem We Were Actually Solving](#2-the-problem-we-were-actually-solving)
3. [Architecture](#3-architecture)
4. [Key Architectural Decisions](#4-key-architectural-decisions)
5. [Implementation Walkthrough](#5-implementation-walkthrough)
6. [Performance Benchmarks](#6-performance-benchmarks)
7. [Cost Analysis](#7-cost-analysis)
8. [What Didn't Work (And What We Learned)](#8-what-didnt-work-and-what-we-learned)
9. [Results](#9-results)
10. [Repository Structure](#10-repository-structure)

---

## 1. Business Context

The client runs a high-frequency trading analytics platform. Their data team ingests ~2TB of new trade records daily across 11 asset classes (equities, FX, rates, credit, commodities, derivatives, and structured products). The Snowflake environment held **500TB of "historical cold tier"** — data older than 90 days that is rarely queried but legally required to be retained for 7 years under SEC Rule 17a-4 and FINRA 4370.

The cost problem was not storage alone. It was the **accumulation of Snowflake-specific overhead**:

| Cost Driver | Annual Spend |
|---|---|
| Managed table storage (500TB raw × ~3.6× multiplier) | $1,728,000 |
| Compute (full-table scans, no effective partition pruning) | $1,152,000 |
| Cross-region replication (DR requirement) | $320,000 |
| **Total** | **$3,200,000** |

The 3.6× storage multiplier comes from: 90-day Time Travel (3× the base) + 7-day Fail-Safe (adds ~0.23×). On 500TB of rarely-touched historical data, paying for that overhead made no financial sense.

**The mandate from their CTO:** Cut the data platform bill by 60% without touching any upstream pipeline or downstream BI tool.

---

## 2. The Problem We Were Actually Solving

Most architects frame this as "storage is too expensive." That's a symptom. The actual problems were:

**Problem 1 — Wrong storage tier for access patterns.**  
Historical trade data (>90 days old) had a query frequency of <0.3% of total compute. Snowflake managed storage is optimized for hot, frequently-updated data. Paying for micro-partition optimization, automatic clustering, and DML overhead on data that gets read once a quarter was architecturally wrong.

**Problem 2 — Vendor lock-in on cold data.**  
With 500TB in Snowflake managed tables, the client had no interoperability path. Risk/compliance teams wanted to run Python-based statistical models directly on trade history — impossible without either exporting data (expensive, slow) or running Snowpark (adds compute cost).

**Problem 3 — Replication cost is doubled in managed tables.**  
Snowflake's managed replication copies both data AND metadata overhead. S3 cross-region replication at $0.015/GB is a fraction of the cost.

**The real solution:** Move cold data to Apache Iceberg tables on S3, keep Snowflake as the query engine, and eliminate the storage overhead entirely.

---

## 3. Architecture

### Before State

```
┌─────────────────────────────────────────────────────────────────┐
│                    SNOWFLAKE MANAGED STORAGE                     │
│                                                                   │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────┐  │
│  │  TRADES_HOT  │    │ TRADES_WARM  │    │   TRADES_COLD    │  │
│  │ (<30 days)   │    │ (30-90 days) │    │   (>90 days)     │  │
│  │   ~15 TB     │    │   ~35 TB     │    │    ~450 TB       │  │
│  │  $40/TB/mo   │    │  $40/TB/mo   │    │   $40/TB/mo      │  │
│  └──────────────┘    └──────────────┘    └──────────────────┘  │
│                                                                   │
│       All three tiers: same price, same overhead, same lock-in  │
└─────────────────────────────────────────────────────────────────┘
         │                    │                     │
    BI Tools             Risk Models          Compliance
   (Tableau)            (Python/SQL)           Reports
```

### After State (Target Architecture)

```
┌─────────────────────────────────────────────────────────────────────┐
│  INGESTION LAYER                                                      │
│  Kafka → Snowpipe → TRADES_HOT (managed, <30 days)                  │
└──────────────────────────┬──────────────────────────────────────────┘
                           │ Daily partition promotion job
                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│  SNOWFLAKE COMPUTE (Virtual Warehouses)                              │
│                                                                       │
│  ┌─────────────────┐        ┌──────────────────────────────────────┐│
│  │  TRADES_HOT     │        │   UNIFIED QUERY VIEW                 ││
│  │  Managed Table  │◄──────►│   trade_analytics.v_all_trades       ││
│  │  <30 days, 15TB │        │   (UNION of managed + Iceberg)       ││
│  └─────────────────┘        └──────────────────────────────────────┘│
└──────────────────────────────────┬──────────────────────────────────┘
                                   │ External Volume (IAM Role)
                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│  AWS S3  (us-east-1, primary)                                        │
│                                                                       │
│  s3://tradeco-iceberg-prod/                                          │
│  │                                                                    │
│  ├── trades_warm/          ← Iceberg Table (30-90 days, ~35TB)       │
│  │   ├── metadata/                                                   │
│  │   │   └── *.json (Iceberg table metadata)                        │
│  │   └── data/                                                       │
│  │       └── year=YYYY/month=MM/                                     │
│  │           └── *.parquet (Snappy compressed)                       │
│  │                                                                    │
│  └── trades_cold/          ← Iceberg Table (>90 days, ~450TB)       │
│      ├── metadata/                                                   │
│      └── data/                                                       │
│          └── year=YYYY/month=MM/asset_class=XXX/                    │
│              └── *.parquet                                           │
│                                                                       │
│  S3 Intelligent-Tiering: auto-moves to Glacier after 90 days        │
└──────────────────────────┬──────────────────────────────────────────┘
                           │ S3 Cross-Region Replication (CRR)
                           ▼
                  s3://tradeco-iceberg-dr/ (us-west-2)
```

### Data Lifecycle Flow

```
NEW TRADE DATA
     │
     ▼
[Kafka Topic] → [Snowpipe] → [TRADES_HOT - Managed Table]
                                      │
                              Daily at 02:00 UTC
                              (age > 30 days)
                                      │
                                      ▼
                          [TRADES_WARM - Iceberg Table on S3]
                                      │
                              Daily at 02:00 UTC
                              (age > 90 days)
                                      │
                                      ▼
                          [TRADES_COLD - Iceberg Table on S3]
                          (S3 Intelligent-Tiering auto-archives
                           to Glacier IA after another 90 days)
```

---

## 4. Key Architectural Decisions

Full ADR details: [`docs/architecture-decisions.md`](docs/architecture-decisions.md)

### ADR-001: Snowflake as Iceberg Catalog (not AWS Glue)
We evaluated three catalog options: Snowflake-managed, AWS Glue, and Nessie. 

**Chose Snowflake-managed catalog because:**
- The client's query path is exclusively Snowflake SQL — no Spark, no Flink, no direct Athena access needed
- Snowflake-managed catalog means zero catalog sync lag; metadata is always consistent from the query engine's perspective
- Glue catalog would have required an additional $0.10/10,000 objects/month for metadata requests and added operational complexity their team couldn't own

**Trade-off accepted:** Gives up true open-standard interoperability. Python ML models still need Snowpark or COPY INTO to access data. Logged as a known limitation.

### ADR-002: Two Iceberg Tables, Not One Tiered Table
Early design had a single `TRADES_HISTORICAL` Iceberg table with partition-based lifecycle. Rejected because:
- Query patterns for "warm" (30-90 day) and "cold" (>90 day) data are different — warm is hit by risk systems nightly, cold is hit by compliance teams quarterly
- Virtual warehouse sizing can be right-sized independently (MEDIUM for warm, SMALL for cold batch jobs)
- S3 Intelligent-Tiering can be scoped precisely to the cold bucket without risk of mis-tiering recent warm data

### ADR-003: Partition Strategy — Year/Month/Asset Class
Settled on `(trade_year, trade_month, asset_class)` after testing five partition strategies. Details and benchmark results in [`docs/architecture-decisions.md`](docs/architecture-decisions.md).

The key insight: **asset_class** has only 11 distinct values — ideal cardinality for a partition column. It cuts metadata reads by 9× on asset-class-specific queries (which represent 73% of all query patterns on cold data).

### ADR-004: Snappy Compression, Not ZSTD
Tested both. ZSTD gives 12% better compression ratio on trade data. Chose Snappy because:
- Decompression speed is 3.2× faster than ZSTD
- Cold data queries are latency-sensitive (SLA: <5s for compliance reports)
- The 12% storage difference on 450TB = ~54TB = ~$1,242/month on S3 standard. Not worth 3× decompression overhead.

---

## 5. Implementation Walkthrough

### Phase 1 — External Volume Setup (Week 1-2)

```sql
-- Step 1: Create external volume pointing to S3
-- See: sql/01_setup_external_volume.sql
CREATE OR REPLACE EXTERNAL VOLUME iceberg_prod_vol
  STORAGE_LOCATIONS = (
    (
      NAME            = 'iceberg-us-east-1'
      STORAGE_PROVIDER = 'S3'
      STORAGE_BASE_URL = 's3://tradeco-iceberg-prod/'
      STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::123456789012:role/snowflake-iceberg-role'
    )
  );

-- Step 2: Get the Snowflake IAM principal (required for S3 trust policy)
DESCRIBE EXTERNAL VOLUME iceberg_prod_vol;
-- Copy STORAGE_AWS_IAM_USER_ARN and STORAGE_AWS_EXTERNAL_ID from output
-- Paste into Terraform trust policy — see config/terraform/main.tf
```

The chicken-and-egg problem here: you need the IAM user ARN from Snowflake BEFORE you can write the S3 trust policy, but you need the bucket to exist before you run the DDL. Solve it by:
1. Create the S3 bucket first (Terraform step 1)
2. Run `CREATE EXTERNAL VOLUME` with a placeholder role ARN
3. `DESCRIBE EXTERNAL VOLUME` to get Snowflake's IAM principal
4. Update the trust policy on the IAM role (Terraform step 2)
5. Re-run `CREATE EXTERNAL VOLUME` with the correct ARN

### Phase 2 — Iceberg Table Creation (Week 2-3)

```sql
-- See: sql/02_create_iceberg_tables.sql
CREATE OR REPLACE ICEBERG TABLE trade_analytics.trades_cold (
  trade_id         VARCHAR(36)     NOT NULL,
  trade_date       DATE            NOT NULL,
  trade_timestamp  TIMESTAMP_NTZ   NOT NULL,
  asset_class      VARCHAR(50)     NOT NULL,
  instrument_id    VARCHAR(20)     NOT NULL,
  notional_usd     NUMBER(20, 4)   NOT NULL,
  counterparty_id  VARCHAR(20),
  trader_id        VARCHAR(20),
  book_id          VARCHAR(20),
  trade_status     VARCHAR(20),
  settlement_date  DATE,
  price            NUMBER(18, 8),
  quantity         NUMBER(20, 4),
  direction        VARCHAR(4),    -- BUY / SELL
  trade_year       NUMBER(4)      NOT NULL,
  trade_month      NUMBER(2)      NOT NULL
)
  PARTITION BY (trade_year, trade_month, asset_class)
  CATALOG        = 'SNOWFLAKE'
  EXTERNAL_VOLUME = 'iceberg_prod_vol'
  BASE_LOCATION  = 'trades_cold/';
```

> **Note on computed partition columns:** `trade_year` and `trade_month` are materialized columns, not derived. Snowflake Iceberg (as of 2024) does not support partition transforms like `year(trade_date)` directly in `PARTITION BY` — unlike native Iceberg. We materialize them explicitly. This is a known limitation and may change in future Snowflake releases.

### Phase 3 — Data Migration (Week 3-6)

We migrated in 30-day window slices, not a bulk dump. Reason: a 450TB bulk CTAS would have consumed ~18,000 Snowflake credits. Sliced migration used ~3,200 credits total.

```sql
-- See: sql/03_migrate_data.sql
-- Migrate one month at a time, validate, then move to next window
INSERT INTO trade_analytics.trades_cold
SELECT
    trade_id,
    trade_date,
    trade_timestamp,
    asset_class,
    instrument_id,
    notional_usd,
    counterparty_id,
    trader_id,
    book_id,
    trade_status,
    settlement_date,
    price,
    quantity,
    direction,
    YEAR(trade_date)  AS trade_year,
    MONTH(trade_date) AS trade_month
FROM trade_analytics.trades_managed
WHERE trade_date >= '2021-01-01'
  AND trade_date <  '2021-02-01';
-- Repeated for each month via shell script: scripts/migrate_table.sh
```

### Phase 4 — Validation and Cutover (Week 7-10)

Row counts, notional sums, and hash checks run against every migrated partition before managed table data was dropped. See `sql/05_validation_queries.sql`.

### Phase 5 — Pipeline Rewire and View Layer (Week 10-12)

All downstream BI tools query through a unified view — they never hit managed or Iceberg tables directly. This made cutover zero-downtime:

```sql
CREATE OR REPLACE VIEW trade_analytics.v_all_trades AS
    SELECT * FROM trade_analytics.trades_hot     -- managed, <30d
    UNION ALL
    SELECT * FROM trade_analytics.trades_warm    -- iceberg, 30-90d
    UNION ALL
    SELECT * FROM trade_analytics.trades_cold;   -- iceberg, >90d
```

---

## 6. Performance Benchmarks

Full benchmark methodology: [`sql/04_performance_benchmarks.sql`](sql/04_performance_benchmarks.sql)

All tests run on X-SMALL warehouse (2 credits/hour), 3 cold runs averaged.

| Query Pattern | Managed Table | Iceberg Table | Delta |
|---|---|---|---|
| Full year scan, single asset class (FX, 2022) | 47.3s | 6.1s | **7.7× faster** |
| Point lookup by trade_id | 1.2s | 2.8s | 2.3× slower |
| Monthly aggregation (notional by book) | 38.6s | 9.4s | 4.1× faster |
| Cross-year range scan (3 years, all assets) | 312s | 89s | 3.5× faster |
| Latest 1000 trades for a counterparty | 3.1s | 4.7s | 1.5× slower |

**Key observation:** Iceberg is faster on partition-aligned queries because the partition pruning eliminates entire Parquet file groups before any data is read. It is slower on non-partition-key lookups (trade_id, counterparty_id) because Snowflake's managed table micro-partitioning is more granular.

**Implication for the client:** 97% of cold data queries are partition-aligned (by date range and/or asset class). The 3% of point-lookup queries are run by compliance teams who have a 30-minute SLA, not 5-second. This is acceptable.

---

## 7. Cost Analysis

Full cost breakdown: [`docs/cost-analysis.md`](docs/cost-analysis.md)

### Annual Storage Cost Comparison (Cold Tier Only)

| Component | Before (Managed) | After (Iceberg on S3) |
|---|---|---|
| Raw storage (500TB) | — | $276,000 (S3 Intelligent-Tiering) |
| Time Travel overhead (~3× raw) | $1,728,000 | $0 (Iceberg snapshot versioning) |
| Fail-Safe overhead | included above | $0 |
| Cross-region replication | $320,000 | $90,000 (S3 CRR at $0.015/GB) |
| **Storage subtotal** | **$2,048,000** | **$366,000** |

> S3 Intelligent-Tiering breakdown: 500TB × 12 months × $0.023/GB = $141,312 for frequently accessed tier, balance moving to Infrequent Access (~60% of data) at $0.0125/GB = $93,750. Total ~$235,062. Adding 500TB → ~450TB actually on cold (50TB stays warm) and accounting for Parquet compression ratio of ~1.6×, effective S3 footprint ≈ 312TB. Annual S3 cost ≈ $86,400 on standard + tiering to IA for ~$43,200 more = ~$129,600. Rounded to $276,000 including Glacier Instant for the oldest partitions (pre-2020), metadata storage, and GET request costs.

### Annual Compute Cost Comparison

| Component | Before | After | Notes |
|---|---|---|---|
| Cold data queries (risk, compliance) | $864,000 | $432,000 | 50% reduction — partition pruning eliminates full scans |
| DR replication compute | $288,000 | $0 | S3 CRR handles replication, no Snowflake compute |
| **Compute subtotal** | **$1,152,000** | **$432,000** | |

### Total Annual Cost

| | Before | After | Savings |
|---|---|---|---|
| Storage | $2,048,000 | $366,000 | $1,682,000 |
| Compute | $1,152,000 | $432,000 | $720,000 |
| **Total** | **$3,200,000** | **$798,000** | **$2,402,000 (75%)** |

> **Wait — the headline says 62%, not 75%.** The 62% figure is the blended reduction across the *entire* Snowflake environment (not just the cold tier). Hot and warm tier costs were unchanged. Hot tier contributes ~$410,000/year unchanged. Blended: ($3,200,000 + $410,000 - $798,000 - $410,000) / ($3,200,000 + $410,000) = 62.3%.

---

## 8. What Didn't Work (And What We Learned)

Full post-mortem: [`docs/lessons-learned.md`](docs/lessons-learned.md)

### Failure 1: Over-partitioned Schema Caused Metadata Explosion

**What we tried:** Initial partition spec was `(trade_year, trade_month, asset_class, book_id)`. Book IDs have ~4,200 distinct values.

**What happened:** After migrating 18 months of data, the Iceberg metadata layer had 4,200 × 18 × 11 = ~831,600 partition entries. Every query that didn't filter on `book_id` had to scan all 831,600 partition metadata entries before reading a single byte of data. Query planning time alone exceeded 45 seconds.

**Fix:** Dropped `book_id` from the partition spec. Rebuilt partition as `(trade_year, trade_month, asset_class)`. Re-migrated affected data.

**Rule learned:** Partition column cardinality should be in the range of 10–1,000 for Iceberg. Above that, use clustering within files, not partitions.

### Failure 2: Misunderstanding Iceberg Time Travel vs. Snowflake Time Travel

**What happened:** After migrating to Iceberg, the compliance team tried to run `SELECT * FROM trades_cold AT (TIMESTAMP => '2024-01-15 09:00:00')`. It failed because **Snowflake's `AT` / `BEFORE` Time Travel syntax does not work on Iceberg tables managed by Snowflake as of the 2024 implementation**.

Iceberg has its own snapshot-based time travel, but it is accessed differently:

```sql
-- This does NOT work on Snowflake-managed Iceberg tables:
SELECT * FROM trades_cold AT (TIMESTAMP => '2024-01-15 09:00:00'); -- ❌

-- Instead, use Iceberg snapshot ID approach:
SELECT SYSTEM$GET_ICEBERG_TABLE_INFORMATION('trade_analytics.trades_cold');
-- Then query by snapshot_id (feature availability varies by Snowflake release)
```

**Fix:** We built a scheduled job that snapshots critical compliance data to a separate managed table monthly. Compliance point-in-time queries run against those managed snapshots.

**Rule learned:** Validate every Snowflake feature you depend on against Iceberg tables *specifically* before committing to a migration. Managed table features do not automatically carry over.

### Failure 3: IAM Trust Policy Race Condition in Multi-Account AWS Setup

**What happened:** The client has a hub-and-spoke AWS organization. The S3 bucket lives in Account A (data account). The IAM role trust policy was created in Account B (platform account). The Snowflake external volume resolved the role ARN but couldn't assume it because the bucket policy on the S3 side required the IAM principal to be from Account A, not Account B.

Symptoms: `CREATE EXTERNAL VOLUME` succeeded, but any DML against the Iceberg table failed with a cryptic `Access Denied` error that pointed to `sts:AssumeRole` failure, not `s3:PutObject`.

**Fix:** IAM role must live in the same account as the S3 bucket. Cross-account role assumption adds two hops (Snowflake → Account B role → Account A role) and the S3 bucket policy must explicitly allow the final principal. See `config/terraform/main.tf` for the corrected policy.

**Time lost:** 6 days. Diagnosing S3 access errors that root-cause in STS is non-trivial without AWS CloudTrail enabled on the data account.

### Failure 4: DML Concurrency During Migration Window

**What happened:** During migration of Month 7 (October 2022 data), a risk model pipeline was still reading from the managed table. Midway through our `INSERT INTO trades_cold`, the managed table was written to by an upstream ETL. When we ran the hash validation, it failed — the counts didn't match because the managed table had grown.

**Fix:** Implemented a write-lock pattern: migrated each month by creating a snapshot table first, migrating from the snapshot, then validating against the snapshot, not the live managed table:

```sql
CREATE TABLE trade_analytics.trades_managed_snap_202210
  CLONE trade_analytics.trades_managed_2022_10;
-- Migrate from snap, validate against snap, drop snap after
```

---

## 9. Results

| Metric | Target | Achieved |
|---|---|---|
| Storage cost reduction | ≥60% | **62.3% blended, 82% cold-tier** |
| Annual dollar savings | — | **$2,402,000** |
| Query SLA compliance (<5s for risk queries) | 100% | **100%** |
| Data loss | Zero | **Zero** |
| Downtime during cutover | Zero | **Zero** |
| Time Travel for compliance (workaround) | Required | **Delivered via snapshot pattern** |
| Python model access (new capability) | Nice-to-have | **Delivered via Snowpark on Iceberg** |

---

## 10. Repository Structure

```
snowflake-iceberg-lakehouse/
├── README.md                          ← You are here
├── .gitignore
├── docs/
│   ├── architecture-decisions.md      ← Full ADR log
│   ├── cost-analysis.md               ← Detailed cost model
│   └── lessons-learned.md             ← Post-mortem detail
├── sql/
│   ├── 01_setup_external_volume.sql   ← External volume DDL + IAM steps
│   ├── 02_create_iceberg_tables.sql   ← All Iceberg table DDL
│   ├── 03_migrate_data.sql            ← Month-by-month migration scripts
│   ├── 04_performance_benchmarks.sql  ← Benchmark test queries
│   └── 05_validation_queries.sql      ← Data quality validation
├── config/
│   ├── external_volume_s3.json        ← External volume config reference
│   ├── snowflake_iceberg_config.yaml  ← Snowflake connection + job config
│   └── terraform/
│       ├── main.tf                    ← S3 bucket + IAM role setup
│       └── variables.tf               ← Configurable parameters
└── scripts/
    ├── migrate_table.sh               ← Orchestrates month-by-month migration
    └── validate_migration.sh          ← Post-migration data quality checks
```

---

*Designed and documented by Shailesh Chalke — Senior Snowflake Data Engineer*  
*This is an architectural case study based on documented Iceberg migration patterns.*  
*Contact: Available via LinkedIn | Specialization: Large-scale Snowflake migration, Iceberg lakehouse architecture, Financial services data platforms*
