#!/usr/bin/env bash
# =============================================================================
# FILE: scripts/migrate_table.sh
# PURPOSE: Orchestrates month-by-month migration from Snowflake managed table
#          to Iceberg on S3. Implements the snapshot-first migration pattern
#          described in docs/lessons-learned.md (Failure 4).
#
# USAGE:
#   ./scripts/migrate_table.sh [OPTIONS]
#
# OPTIONS:
#   --config PATH        Path to config YAML (default: config/snowflake_iceberg_config.yaml)
#   --start-date DATE    Migration start date YYYY-MM-DD (default: from config)
#   --end-date DATE      Migration end date YYYY-MM-DD (default: from config)
#   --dry-run            Print SQL that would be executed, but don't run it
#   --skip-validation    Skip post-migration validation (NOT recommended for production)
#   --resume-from DATE   Resume a failed migration from a specific month (YYYY-MM-DD)
#   --threads N          Number of parallel migration threads (default: from config, max: 4)
#
# PREREQUISITES:
#   - SnowSQL CLI installed and configured (snowsql -v should work)
#   - Environment variables set: SNOWFLAKE_ACCOUNT, SNOWFLAKE_USER, SNOWFLAKE_PASSWORD
#   - sql/01_setup_external_volume.sql already executed
#   - sql/02_create_iceberg_tables.sql already executed
#   - AWS CLI configured (for S3 size verification)
#
# EXAMPLES:
#   # Full migration with config defaults:
#   ./scripts/migrate_table.sh
#
#   # Dry run to preview SQL:
#   ./scripts/migrate_table.sh --dry-run
#
#   # Resume after failure at 2021-06-01:
#   ./scripts/migrate_table.sh --resume-from 2021-06-01
#
#   # Migrate specific date range only:
#   ./scripts/migrate_table.sh --start-date 2022-01-01 --end-date 2022-12-31
# =============================================================================

set -euo pipefail

# =============================================================================
# CONSTANTS AND DEFAULTS
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/snowflake_iceberg_config.yaml"
LOG_DIR="${PROJECT_ROOT}/logs"
LOG_FILE="${LOG_DIR}/migration_$(date +%Y%m%d_%H%M%S).log"
DRY_RUN=false
SKIP_VALIDATION=false
RESUME_FROM=""
PARALLEL_THREADS=2

# Colours for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No colour

# =============================================================================
# ARGUMENT PARSING
# =============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)         CONFIG_FILE="$2"; shift 2 ;;
        --start-date)     START_DATE_OVERRIDE="$2"; shift 2 ;;
        --end-date)       END_DATE_OVERRIDE="$2"; shift 2 ;;
        --dry-run)        DRY_RUN=true; shift ;;
        --skip-validation) SKIP_VALIDATION=true; shift ;;
        --resume-from)    RESUME_FROM="$2"; shift 2 ;;
        --threads)        PARALLEL_THREADS="$2"; shift 2 ;;
        --help)
            head -50 "${BASH_SOURCE[0]}" | grep "^#" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S UTC')
    local colour=""
    case "$level" in
        INFO)    colour="${BLUE}" ;;
        SUCCESS) colour="${GREEN}" ;;
        WARN)    colour="${YELLOW}" ;;
        ERROR)   colour="${RED}" ;;
    esac
    echo -e "${colour}[${timestamp}] [${level}] ${msg}${NC}" | tee -a "${LOG_FILE}"
}

check_prerequisites() {
    log "INFO" "Checking prerequisites..."

    # Validate password is set as env var (not passed via --password flag)
    if [[ -z "${SNOWSQL_PWD:-}" ]]; then
        if [[ -n "${SNOWFLAKE_PASSWORD:-}" ]]; then
            # Auto-export to SNOWSQL_PWD (SnowSQL reads this automatically)
            export SNOWSQL_PWD="${SNOWFLAKE_PASSWORD}"
            log "WARN" "SNOWFLAKE_PASSWORD found. Auto-setting SNOWSQL_PWD. Prefer setting SNOWSQL_PWD directly."
        else
            log "ERROR" "Neither SNOWSQL_PWD nor SNOWFLAKE_PASSWORD is set."
            exit 1
        fi
    fi

    # Check SnowSQL
    if ! command -v snowsql &> /dev/null; then
        log "ERROR" "snowsql CLI not found. Install from: https://docs.snowflake.com/en/user-guide/snowsql-install-config"
        exit 1
    fi

    # Check required environment variables
    for var in SNOWFLAKE_ACCOUNT SNOWFLAKE_USER SNOWFLAKE_PASSWORD; do
        if [[ -z "${!var:-}" ]]; then
            log "ERROR" "Required environment variable \$${var} is not set."
            exit 1
        fi
    done

    # Check AWS CLI (for S3 size verification)
    if ! command -v aws &> /dev/null; then
        log "WARN" "AWS CLI not found. S3 size verification will be skipped."
    fi

    log "SUCCESS" "All prerequisites satisfied."
}

# Execute SQL in Snowflake via SnowSQL
# Returns: exit code (0 = success, non-zero = failure)
run_snowsql() {
    local sql="$1"
    local description="${2:-Running SQL}"

    log "INFO" "SQL: ${description}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "--- DRY RUN SQL ---"
        echo "${sql}"
        echo "-------------------"
        return 0
    fi

    echo "${sql}" | snowsql \
        --accountname  "${SNOWFLAKE_ACCOUNT}" \
        --username     "${SNOWFLAKE_USER}" \
        --rolename     MIGRATION_ROLE \
        --warehousename MIGRATION_WH \
        --dbname       TRADE_ANALYTICS \
        --schemaname   MANAGED \
        --option       output_format=plain \
        --option       friendly=false \
        --option       timing=true \
        --query        "${sql}" 2>&1 | tee -a "${LOG_FILE}"

    return ${PIPESTATUS[0]}
}

# Generate list of months between start and end date (inclusive)
generate_month_list() {
    local start="$1"
    local end="$2"
    local current="${start}"

    while [[ "${current}" <= "${end}" ]]; do
        echo "${current}"
        # Advance to first day of next month (portable date arithmetic)
        local year month
        year=$(echo "${current}" | cut -d'-' -f1)
        month=$(echo "${current}" | cut -d'-' -f2)
        if [[ "${month}" == "12" ]]; then
            year=$((year + 1))
            month="01"
        else
            month=$(printf "%02d" $((10#${month} + 1)))
        fi
        current="${year}-${month}-01"
    done
}

# Get last day of a given month (YYYY-MM-01 format input)
get_month_end() {
    local month_start="$1"
    date -d "${month_start} + 1 month - 1 day" '+%Y-%m-%d' 2>/dev/null \
        || python3 -c "
import datetime
d = datetime.datetime.strptime('${month_start}', '%Y-%m-%d')
next_month = d.replace(day=28) + datetime.timedelta(days=4)
print((next_month - datetime.timedelta(days=next_month.day)).strftime('%Y-%m-%d'))
"
}

# =============================================================================
# CORE MIGRATION FUNCTIONS
# =============================================================================

migrate_month() {
    local month_start="$1"
    local month_end
    month_end=$(get_month_end "${month_start}")

    local year month snap_suffix
    year=$(echo "${month_start}" | cut -d'-' -f1)
    month=$(echo "${month_start}" | cut -d'-' -f2)
    snap_suffix="${year}${month}"

    log "INFO" "━━━━ Starting migration: ${year}-${month} (${month_start} → ${month_end}) ━━━━"

    # PHASE A: Check if already migrated (idempotent re-run safety)
    local existing_count
    existing_count=$(run_snowsql "
        SELECT COUNT(*) 
        FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD 
        WHERE trade_year = ${year} AND trade_month = ${month#0};
    " "Check existing Iceberg rows for ${year}-${month}")

    # Parse count from SnowSQL output (extract the numeric value)
    local count_val
    count_val=$(echo "${existing_count}" | grep -E '^\s*[0-9]+\s*$' | tr -d ' ' | tail -1)

    if [[ -n "${count_val}" && "${count_val}" -gt 0 ]]; then
        log "WARN" "Partition ${year}-${month} already has ${count_val} rows in Iceberg. Skipping (use --force to override)."
        return 0
    fi

    # PHASE B: Create snapshot clone
    run_snowsql "
        DROP TABLE IF EXISTS TRADE_ANALYTICS.MANAGED.MIGRATION_SNAP_${snap_suffix};
        CREATE TABLE TRADE_ANALYTICS.MANAGED.MIGRATION_SNAP_${snap_suffix}
            CLONE TRADE_ANALYTICS.MANAGED.TRADES_COLD_LEGACY;
    " "Create snapshot clone for ${year}-${month}"

    # PHASE C: Get source row count from snapshot
    local source_count
    source_count=$(run_snowsql "
        SELECT COUNT(*) 
        FROM TRADE_ANALYTICS.MANAGED.MIGRATION_SNAP_${snap_suffix}
        WHERE trade_date >= '${month_start}' AND trade_date <= '${month_end}';
    " "Count source rows in snapshot ${year}-${month}")

    local src_rows
    src_rows=$(echo "${source_count}" | grep -E '^\s*[0-9]+\s*$' | tr -d ' ' | tail -1)
    log "INFO" "Source row count for ${year}-${month}: ${src_rows}"

    # PHASE D: Migrate data from snapshot to Iceberg
    run_snowsql "
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
            trade_id, trade_date, trade_timestamp, asset_class, instrument_id,
            instrument_name, instrument_subtype, notional_usd, notional_local,
            local_currency, price, quantity, direction, counterparty_id,
            counterparty_lei, trader_id, book_id, desk_id, entity_id, trade_status,
            settlement_date, value_date, maturity_date, uti, mifid_flag,
            reporting_status, created_at, updated_at, source_system,
            YEAR(trade_date)  AS trade_year,
            MONTH(trade_date) AS trade_month
        FROM TRADE_ANALYTICS.MANAGED.MIGRATION_SNAP_${snap_suffix}
        WHERE trade_date >= '${month_start}'
          AND trade_date <= '${month_end}';
    " "INSERT INTO Iceberg from snapshot ${year}-${month}"

    # PHASE E: Validate (unless --skip-validation)
    if [[ "${SKIP_VALIDATION}" == "false" ]]; then
        validate_month "${year}" "${month#0}" "${month_start}" "${month_end}" "${snap_suffix}"
        local validation_status=$?
        if [[ ${validation_status} -ne 0 ]]; then
            log "ERROR" "Validation FAILED for ${year}-${month}. Snapshot preserved for investigation: MIGRATION_SNAP_${snap_suffix}"
            return 1
        fi
    fi

    # PHASE F: Log to migration audit table
    run_snowsql "
        INSERT INTO TRADE_ANALYTICS.MANAGED.MIGRATION_LOG 
            (source_table, target_table, partition_start, partition_end, rows_migrated, status)
        VALUES (
            'TRADES_COLD_LEGACY', 
            'ICEBERG.TRADES_COLD', 
            '${month_start}', 
            '${month_end}', 
            ${src_rows:-0}, 
            'COMPLETED'
        );
    " "Log migration completion for ${year}-${month}"

    # PHASE G: Drop snapshot (validation passed)
    run_snowsql "
        DROP TABLE IF EXISTS TRADE_ANALYTICS.MANAGED.MIGRATION_SNAP_${snap_suffix};
    " "Drop snapshot for ${year}-${month}"

    log "SUCCESS" "━━━━ Completed migration: ${year}-${month} (${src_rows} rows) ━━━━"
    return 0
}

validate_month() {
    local year="$1"
    local month="$2"
    local month_start="$3"
    local month_end="$4"
    local snap_suffix="$5"

    log "INFO" "Running validation for ${year}-${month}..."

    # Row count check
    local validation_result
    validation_result=$(run_snowsql "
        WITH src AS (
            SELECT COUNT(*) AS cnt
            FROM TRADE_ANALYTICS.MANAGED.MIGRATION_SNAP_${snap_suffix}
            WHERE trade_date >= '${month_start}' AND trade_date <= '${month_end}'
        ),
        tgt AS (
            SELECT COUNT(*) AS cnt
            FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD
            WHERE trade_year = ${year} AND trade_month = ${month}
        )
        SELECT 
            CASE WHEN src.cnt = tgt.cnt THEN 'PASS' ELSE 'FAIL' END AS result,
            src.cnt AS source_rows,
            tgt.cnt AS target_rows
        FROM src, tgt;
    " "Row count validation ${year}-${month}")

    if echo "${validation_result}" | grep -q "FAIL"; then
        log "ERROR" "Row count validation FAILED for ${year}-${month}"
        log "ERROR" "${validation_result}"
        return 1
    fi

    # Notional sum check
    local notional_check
    notional_check=$(run_snowsql "
        WITH src AS (SELECT SUM(notional_usd) AS s FROM TRADE_ANALYTICS.MANAGED.MIGRATION_SNAP_${snap_suffix} WHERE trade_date >= '${month_start}' AND trade_date <= '${month_end}'),
             tgt AS (SELECT SUM(notional_usd) AS s FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD WHERE trade_year = ${year} AND trade_month = ${month})
        SELECT CASE WHEN ABS(src.s - tgt.s) < 0.01 THEN 'PASS' ELSE 'FAIL' END AS result
        FROM src, tgt;
    " "Notional sum validation ${year}-${month}")

    if echo "${notional_check}" | grep -q "FAIL"; then
        log "ERROR" "Notional sum validation FAILED for ${year}-${month}"
        return 1
    fi

    # Partition column consistency check
    local partition_check
    partition_check=$(run_snowsql "
        SELECT COUNT(*) AS bad_rows
        FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD
        WHERE trade_year = ${year} AND trade_month = ${month}
          AND (YEAR(trade_date) != trade_year OR MONTH(trade_date) != trade_month);
    " "Partition column consistency ${year}-${month}")

    local bad_rows
    bad_rows=$(echo "${partition_check}" | grep -E '^\s*[0-9]+\s*$' | tr -d ' ' | tail -1)
    if [[ -n "${bad_rows}" && "${bad_rows}" -gt 0 ]]; then
        log "ERROR" "Partition column consistency check FAILED: ${bad_rows} rows with mismatched trade_year/trade_month"
        return 1
    fi

    log "SUCCESS" "All validation checks PASSED for ${year}-${month}"
    return 0
}

run_compaction_for_year() {
    local year="$1"
    log "INFO" "Running file compaction for year ${year}..."
    run_snowsql "
        ALTER ICEBERG TABLE TRADE_ANALYTICS.ICEBERG.TRADES_COLD
            EXECUTE FILE_COMPACTION
            WHERE trade_year = ${year};
    " "File compaction for year ${year}"
    log "SUCCESS" "Compaction complete for year ${year}"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    mkdir -p "${LOG_DIR}"
    log "INFO" "============================================================"
    log "INFO" " Snowflake Iceberg Migration — migrate_table.sh"
    log "INFO" " Started: $(date '+%Y-%m-%d %H:%M:%S UTC')"
    log "INFO" " Config:  ${CONFIG_FILE}"
    log "INFO" " Dry run: ${DRY_RUN}"
    log "INFO" "============================================================"

    check_prerequisites

    # Load date range from config or overrides
    # Default to 2019-01-01 → 2023-12-31 if config parsing not available
    START_DATE="${START_DATE_OVERRIDE:-2019-01-01}"
    END_DATE="${END_DATE_OVERRIDE:-2023-12-31}"

    # Apply resume-from offset
    if [[ -n "${RESUME_FROM}" ]]; then
        START_DATE="${RESUME_FROM}"
        log "INFO" "Resuming migration from: ${START_DATE}"
    fi

    log "INFO" "Migration window: ${START_DATE} → ${END_DATE}"

    # Generate list of months to migrate
    local months=()
    while IFS= read -r month; do
        months+=("${month}")
    done < <(generate_month_list "${START_DATE}" "${END_DATE}")

    local total_months=${#months[@]}
    local completed=0
    local failed=0
    local current_year=""
    local prev_year=""

    log "INFO" "Total months to migrate: ${total_months}"

    for month_start in "${months[@]}"; do
        current_year=$(echo "${month_start}" | cut -d'-' -f1)

        # Run compaction at year boundary (after completing previous year)
        if [[ -n "${prev_year}" && "${current_year}" != "${prev_year}" ]]; then
            run_compaction_for_year "${prev_year}"
        fi

        if migrate_month "${month_start}"; then
            completed=$((completed + 1))
            log "INFO" "Progress: ${completed}/${total_months} months complete (${failed} failed)"
        else
            failed=$((failed + 1))
            log "ERROR" "Migration failed for ${month_start}. Stopping."
            log "ERROR" "To resume: ./scripts/migrate_table.sh --resume-from ${month_start}"
            break
        fi

        prev_year="${current_year}"
    done

    # Run compaction for the final year
    if [[ -n "${current_year}" && ${failed} -eq 0 ]]; then
        run_compaction_for_year "${current_year}"
    fi

    log "INFO" "============================================================"
    log "INFO" " Migration Summary"
    log "INFO" " Completed months: ${completed}/${total_months}"
    log "INFO" " Failed months:    ${failed}"
    log "INFO" " Log file:         ${LOG_FILE}"
    log "INFO" "============================================================"

    if [[ ${failed} -gt 0 ]]; then
        log "ERROR" "Migration completed with failures. Check log: ${LOG_FILE}"
        exit 1
    else
        log "SUCCESS" "Migration completed successfully."
        log "INFO" "NEXT STEP: Run scripts/validate_migration.sh for full post-migration validation."
        exit 0
    fi
}

main "$@"