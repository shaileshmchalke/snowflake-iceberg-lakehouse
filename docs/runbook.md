# Operational Runbook — Snowflake Iceberg Lakehouse

> **Audience:** On-call data engineer, data platform lead  
> **Purpose:** Day-to-day operational procedures post-migration  
> **Last updated:** 2024-05-01

---

## 1. Daily Health Checks (5 minutes)

### 1.1 Verify Nightly Tier Promotion Ran Successfully

```sql
-- Run in Snowflake every morning
SELECT
    name,
    state,
    scheduled_time,
    completed_time,
    error_message
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    SCHEDULED_TIME_RANGE_START => DATEADD('day', -1, CURRENT_TIMESTAMP()),
    RESULT_LIMIT => 5
))
WHERE name = 'TASK_DAILY_TIER_PROMOTION'
ORDER BY scheduled_time DESC;
```

**Expected:** `state = SUCCEEDED`, `error_message = NULL`

**If FAILED:**
1. Check `error_message` column — usually a warehouse timeout
2. Resume task: `ALTER TASK TASK_DAILY_TIER_PROMOTION RESUME;`
3. Manually trigger: `EXECUTE TASK TASK_DAILY_TIER_PROMOTION;`
4. Re-run validation: `./scripts/validate_migration.sh`

### 1.2 Check Iceberg Table Accessibility

```sql
SELECT COUNT(*) FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD
WHERE trade_year = YEAR(CURRENT_DATE()) LIMIT 1;
```

**If error:** See Section 4 (Troubleshooting).

---

## 2. Monthly Tasks (1st of each month)

### 2.1 Verify Compliance Snapshot Was Created

```sql
-- Check snapshot was created for last month
SELECT table_name, created, ROW_COUNT
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'SNAPSHOTS'
  AND TABLE_NAME = 'TRADES_COLD_SNAP_' ||
      TO_CHAR(DATEADD('month', -1, CURRENT_DATE()), 'YYYYMM');
```

**If missing — manually create:**

```sql
CALL TRADE_ANALYTICS.SNAPSHOTS.SP_MONTHLY_SNAPSHOT();
```

### 2.2 Run Storage Cost Report

```sql
SELECT
    table_name,
    ROUND(active_bytes / POWER(1024,4), 3)            AS active_tb,
    ROUND(time_travel_bytes / POWER(1024,4), 3)       AS tt_tb,
    ROUND(failsafe_bytes / POWER(1024,4), 3)          AS failsafe_tb,
    ROUND((active_bytes + time_travel_bytes + failsafe_bytes)
          / POWER(1024,4) * 40, 2)                    AS est_monthly_usd
FROM INFORMATION_SCHEMA.TABLE_STORAGE_METRICS
WHERE TABLE_CATALOG = 'TRADE_ANALYTICS'
ORDER BY est_monthly_usd DESC;
```

**Alert threshold:** If cold tier managed storage > $50K/month → investigate unexpected data in managed tier.

### 2.3 Snapshot Retention Cleanup

The SP_MONTHLY_SNAPSHOT procedure auto-drops 14-month-old snapshots. Verify:

```sql
SELECT table_name, created
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'SNAPSHOTS'
ORDER BY table_name DESC;
-- Should have no more than 13 rows
```

---

## 3. Quarterly Tasks

### 3.1 Run Full Validation Suite

```bash
./scripts/validate_migration.sh \
    --start-date 2019-01-01 \
    --end-date 2023-12-31 \
    --output-report
# Review: logs/validation_report_YYYYMMDD.log
# All checks must show PASS
```

### 3.2 Run Compaction on Previous Year

After all 12 months of a year are in the cold tier, run compaction:

```bash
./scripts/compaction.sh --year 2019 --year 2020 --year 2021
# Runtime: 10-30 min per year on MEDIUM warehouse
# Cost: ~10-15 credits per year
```

### 3.3 DR Drill

See `docs/dr-runbook.md` for full DR drill procedure.
Target: RTO < 4 hours, RPO < 15 minutes.

---

## 4. Troubleshooting

### Problem: "External volume is not accessible" error

```
SQL compilation error: External volume 'ICEBERG_PROD_VOL' is not accessible.
```

**Diagnosis steps:**

```bash
# Step 1: Check if S3 bucket is accessible
aws s3 ls s3://tradeco-iceberg-prod/ --region us-east-1

# Step 2: Verify IAM role trust policy hasn't changed
aws iam get-role --role-name snowflake-iceberg-role

# Step 3: In Snowflake — re-describe the volume
DESCRIBE EXTERNAL VOLUME iceberg_prod_vol;
# Check STORAGE_AWS_IAM_USER_ARN still matches IAM trust policy
```

**Most common cause:** IAM role trust policy was modified or rotated. See `docs/lessons-learned.md` Failure 3.

---

### Problem: Tier promotion task keeps failing

```
Error: Iceberg table TRADES_WARM: write operation failed
```

**Check:**

```sql
-- Are there duplicate trade_ids being promoted?
SELECT trade_id, COUNT(*) FROM TRADE_ANALYTICS.MANAGED.TRADES_HOT
WHERE trade_date < DATEADD('day', -30, CURRENT_DATE())
GROUP BY trade_id HAVING COUNT(*) > 1
LIMIT 10;
```

If duplicates exist → fix upstream before re-running promotion.

---

### Problem: Compliance Time Travel query fails

```
Error: Time Travel is not supported for Iceberg tables.
```

**This is expected.** Use compliance snapshot tables instead:

```sql
-- Instead of: SELECT * FROM trades_cold AT (TIMESTAMP => ...)
-- Use the monthly snapshot:
SELECT * FROM TRADE_ANALYTICS.SNAPSHOTS.TRADES_COLD_SNAP_202401
WHERE trade_date BETWEEN '2024-01-01' AND '2024-01-31';
```

See `docs/lessons-learned.md` Failure 2 for full explanation.

---

### Problem: S3 Replication lag alert

**Check CRR lag in AWS CloudWatch:**

```
Metric: ReplicationLatency
Namespace: AWS/S3
Dimensions: SourceBucket=tradeco-iceberg-prod, DestinationBucket=tradeco-iceberg-dr
```

**Acceptable:** < 15 minutes  
**Alert:** > 1 hour → open AWS support P2 ticket  
**DR trigger:** > 4 hours → follow `docs/dr-runbook.md` Scenario 1

---

## 5. Scheduled Jobs Reference

| Job | Schedule | Warehouse | What it does |
|---|---|---|---|
| `TASK_DAILY_TIER_PROMOTION` | Daily 02:00 UTC | TRADE_HOT_WH | Promotes hot→warm→cold |
| `TASK_MONTHLY_SNAPSHOT` | 1st of month 03:00 UTC | ANALYST_WH | Creates compliance snapshot |

**Check all task statuses:**

```sql
SELECT name, state, definition
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    DATE_RANGE_START => DATEADD('day', -7, CURRENT_TIMESTAMP()),
    RESULT_LIMIT => 20
))
ORDER BY scheduled_time DESC;
```

---

## 6. Emergency Contacts

| Situation | Contact | SLA |
|---|---|---|
| S3 outage | AWS Support (P1 ticket) | < 15 min |
| Snowflake outage | Snowflake support portal | < 30 min |
| Data corruption suspected | Data Platform Lead | Immediate |
| Compliance query failure | Compliance team + Data Lead | < 2 hours |