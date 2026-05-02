# Architecture Decision Records

## ADR-001: Snowflake-Managed Iceberg Catalog vs. AWS Glue vs. Nessie

**Date:** 2024-02-12  
**Status:** Accepted  
**Deciders:** Lead Architect (Shailesh Chalke), Client Data Platform Lead, Client Security Architect

### Context

Apache Iceberg tables require a catalog to track table metadata, snapshots, and schema evolution. Three options were evaluated:

| Catalog | Cost Model | Interoperability | Operational Complexity |
|---|---|---|---|
| Snowflake-managed | Included in Snowflake contract | Snowflake-only | Low |
| AWS Glue | $1/100K objects + $0.44/DDU | Any engine (Spark, Athena, Snowflake) | Medium |
| Apache Nessie | Open source + infra cost | Multi-engine | High |

### Decision

**Snowflake-managed catalog.**

### Rationale

1. The client's operational footprint is 100% Snowflake SQL for querying. They have no active Spark, EMR, or Athena workloads.
2. Snowflake-managed catalog guarantees metadata consistency — there is no catalog sync lag that could cause stale reads or version conflicts.
3. Glue DDU (Data Unit) costs are unpredictable at 500TB scale and would require dedicated monitoring.
4. The client's 3-person data platform team does not have Nessie operational experience.

### Consequences

- Iceberg files are standard Parquet + Iceberg metadata; they CAN be read by other engines if needed.
- However, Snowflake's Iceberg metadata format is tied to Snowflake catalog APIs. Migrating catalog to Glue later would require a `CREATE OR REPLACE ICEBERG TABLE ... CATALOG = 'GLUE'` migration.
- Python ML models must use Snowpark (not direct PyIceberg) for the foreseeable future.

---

## ADR-002: Two Iceberg Tables vs. Single Tiered Table

**Date:** 2024-02-19  
**Status:** Accepted

### Context

Initial design proposed one `TRADES_HISTORICAL` Iceberg table covering all data older than 30 days, with S3 Intelligent-Tiering handling storage cost optimization automatically.

### Problem with Single Table Design

Testing revealed two incompatible query patterns:

| Pattern | Warm (30-90 days) | Cold (>90 days) |
|---|---|---|
| Access frequency | Nightly (risk batches) | Quarterly (compliance) |
| Typical query shape | Date range + asset class, last 60 days | Full-year aggregations |
| Acceptable latency | <5 seconds | <30 seconds |
| Warehouse size needed | MEDIUM | SMALL |

A single table forces the worst-case warehouse size for all queries. Splitting allows independent right-sizing.

Additionally, S3 Intelligent-Tiering applies a per-object monitoring fee ($0.0025/1,000 objects). Cold data files are accessed so infrequently they should move to Glacier Instant Retrieval, not Intelligent-Tiering. Separating warm and cold into different S3 prefixes/buckets allows different S3 lifecycle policies.

### Decision

Two Iceberg tables: `TRADES_WARM` (30-90 days) on S3 Standard/Intelligent-Tiering, `TRADES_COLD` (>90 days) on S3 with Glacier Instant Retrieval lifecycle after 90 days in S3.

---

## ADR-003: Partition Strategy Evaluation

**Date:** 2024-02-26  
**Status:** Accepted (after Failure 1 correction — see lessons-learned.md)

### Candidates Tested

Five partition strategies were benchmarked on a 50TB sample (2 years of FX data):

| Strategy | Query Plan Time | Scan Size (typical) | Partition Count |
|---|---|---|---|
| `(trade_year)` | 0.1s | Full year | 3 |
| `(trade_year, trade_month)` | 0.1s | 1 month | 36 |
| `(trade_year, trade_month, asset_class)` | 0.1s | 1 month × 1 asset | 396 |
| `(trade_year, trade_month, asset_class, book_id)` | 45.2s | 1 month × 1 asset × 1 book | **831,600** |
| `(trade_year, trade_month, direction)` | 0.1s | 1 month × BUY or SELL | 72 |

### Decision

`(trade_year, trade_month, asset_class)` — Strategy 3.

### Rationale

- 73% of cold data queries filter on both date range and asset class. This partition spec eliminates all non-matching asset classes before any file is opened.
- 396 partition entries is well within the "safe zone" for Iceberg metadata (recommended <10,000).
- Adding `direction` (Strategy 5) provides marginal benefit — only 8% of queries filter on direction — and doubles partition count.
- Book ID was explicitly rejected after the metadata explosion failure (see lessons-learned.md).

### File Sizing Target

Target 512MB–1GB Parquet files per partition. This was achieved by batching migration in full-month windows and running `ALTER ICEBERG TABLE ... EXECUTE FILE_COMPACTION` post-migration on any partition with files <128MB.

---

## ADR-004: Snappy vs. ZSTD Compression

**Date:** 2024-03-05  
**Status:** Accepted

### Benchmark (50TB sample, FX data 2022)

| Codec | Compressed Size | Compression Time | Decompression Speed | S3 Annual Delta |
|---|---|---|---|---|
| Snappy | 31.2TB | baseline | baseline | — |
| ZSTD (level 3) | 27.4TB | +18% | 3.2× slower | -$43,800 savings |

### Decision

**Snappy.**

### Rationale

The compliance report SLA is <30 seconds but practically the team expects sub-5 seconds for report refresh. On 450TB of cold data, decompression speed dominates query latency more than file read I/O. The $43,800/year saving from ZSTD does not justify adding 3.2× decompression time.

**Note:** This decision should be re-evaluated if the client's query pattern shifts toward extract-heavy batch workloads (e.g., full dataset exports). ZSTD would be clearly correct in that case.

---

## ADR-005: Zero-Downtime Cutover via View Abstraction

**Date:** 2024-04-01  
**Status:** Accepted

### Context

The client has 47 Tableau workbooks and 12 internal Python scripts that query trade data. Coordinating a synchronized cutover across all consumers was operationally infeasible.

### Decision

All consumers query through `trade_analytics.v_all_trades` — a UNION ALL view that spans managed and Iceberg tables. During migration, the view progressively shifts the partition boundary:

```
Week 3-6 (migration running):
  v_all_trades = trades_hot (managed) 
               + trades_warm (managed, not yet migrated) 
               + trades_cold (managed, not yet migrated)

Week 7-10 (migration complete, validation passing):
  v_all_trades = trades_hot (managed)
               + trades_warm (iceberg)    ← switched
               + trades_cold (iceberg)    ← switched

Week 14 (original managed tables dropped):
  Same view, same query results, lower cost
```

Consumers never changed a single line of SQL. Tableau workbooks were never touched.

### Consequences

- View overhead is negligible (<50ms) for single-table queries
- UNION ALL across managed + Iceberg in the same query has no known performance issues in Snowflake
- View DDL must be maintained if table schemas evolve (managed constraint)