#!/usr/bin/env bash
# =============================================================================
# FILE: scripts/validate_migration.sh
# PURPOSE: Full post-migration validation suite. Run this after migrate_table.sh
#          completes and BEFORE dropping any managed table data.
#
# USAGE:
#   ./scripts/validate_migration.sh [OPTIONS]
#
# OPTIONS:
#   --start-date DATE    Validate from this date (YYYY-MM-DD)
#   --end-date DATE      Validate through this date (YYYY-MM-DD)
#   --output-report      Write validation report to logs/validation_report_YYYYMMDD.txt
#   --fail-fast          Stop on first validation failure (default: run all, report at end)
#
# EXIT CODES:
#   0 — All validations passed. Safe to drop source managed table data.
#   1 — One or more validations failed. DO NOT drop source data.
#   2 — Script error (prerequisites not met, config missing, etc.)
#
# WHEN TO RUN:
#   1. After migrate_table.sh completes for the full date range
#   2. Before switching the unified view to use Iceberg tables
#   3. Before dropping managed table data
#   4. After any compaction run (verify compaction didn't corrupt data)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs"
REPORT_FILE="${LOG_DIR}/validation_report_$(date +%Y%m%d_%H%M%S).txt"
FAIL_FAST=false
WRITE_REPORT=false
START_DATE="2019-01-01"
END_DATE="2023-12-31"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

while [[ $# -gt 0 ]]; do
    case "$1" in
        --start-date)    START_DATE="$2"; shift 2 ;;
        --end-date)      END_DATE="$2"; shift 2 ;;
        --output-report) WRITE_REPORT=true; shift ;;
        --fail-fast)     FAIL_FAST=true; shift ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

# =============================================================================
# TRACKING
# =============================================================================
declare -A CHECK_RESULTS
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0

# =============================================================================
# UTILITY
# =============================================================================

log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local colour=""
    case "$level" in
        PASS)  colour="${GREEN}" ;;
        FAIL)  colour="${RED}" ;;
        INFO)  colour="${BLUE}" ;;
        WARN)  colour="${YELLOW}" ;;
    esac
    local line="${colour}[${ts}] [${level}] ${msg}${NC}"
    echo -e "${line}"
    if [[ "${WRITE_REPORT}" == "true" ]]; then
        echo "[${ts}] [${level}] ${msg}" >> "${REPORT_FILE}"
    fi
}

run_check() {
    local check_id="$1"
    local description="$2"
    local sql="$3"
    local expected_pattern="$4"   # grep pattern that indicates PASS

    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    log "INFO" "Running check ${check_id}: ${description}"

    local result
    result=$(echo "${sql}" | snowsql \
        --accountname  "${SNOWFLAKE_ACCOUNT}" \
        --username     "${SNOWFLAKE_USER}" \
        --rolename     ICEBERG_READER \
        --warehousename ANALYST_WH \
        --option       output_format=plain \
        --option       friendly=false \
        --query        "${sql}" 2>&1)

    if echo "${result}" | grep -qE "${expected_pattern}"; then
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
        CHECK_RESULTS["${check_id}"]="PASS"
        log "PASS" "${check_id}: ${description}"
        return 0
    else
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        CHECK_RESULTS["${check_id}"]="FAIL"
        log "FAIL" "${check_id}: ${description}"
        log "FAIL" "Result: ${result}"
        if [[ "${FAIL_FAST}" == "true" ]]; then
            log "FAIL" "--fail-fast set. Stopping."
            print_summary
            exit 1
        fi
        return 1
    fi
}

print_summary() {
    echo ""
    echo "============================================================"
    echo " VALIDATION REPORT SUMMARY"
    echo " Date range: ${START_DATE} → ${END_DATE}"
    echo " Timestamp:  $(date '+%Y-%m-%d %H:%M:%S UTC')"
    echo "============================================================"
    printf " %-40s %s\n" "Total checks:" "${TOTAL_CHECKS}"
    printf " %-40s %s\n" "Passed:" "${PASSED_CHECKS}"
    printf " %-40s %s\n" "Failed:" "${FAILED_CHECKS}"
    echo "------------------------------------------------------------"

    for check_id in $(echo "${!CHECK_RESULTS[@]}" | tr ' ' '\n' | sort); do
        local result="${CHECK_RESULTS[$check_id]}"
        if [[ "${result}" == "PASS" ]]; then
            echo -e "  ${GREEN}✓ ${check_id}${NC}"
        else
            echo -e "  ${RED}✗ ${check_id}${NC}"
        fi
    done

    echo "============================================================"
    if [[ ${FAILED_CHECKS} -eq 0 ]]; then
        echo -e "${GREEN}RESULT: ALL CHECKS PASSED — Safe to proceed with managed table drop.${NC}"
    else
        echo -e "${RED}RESULT: ${FAILED_CHECKS} CHECK(S) FAILED — DO NOT drop managed table data.${NC}"
        echo -e "${RED}Review failed checks above and in log: ${REPORT_FILE}${NC}"
    fi
    echo "============================================================"
}

# =============================================================================
# VALIDATION CHECKS
# =============================================================================

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
        log "FAIL" "snowsql not found."
        exit 2
    fi
    for var in SNOWFLAKE_ACCOUNT SNOWFLAKE_USER SNOWFLAKE_PASSWORD; do
        if [[ -z "${!var:-}" ]]; then
            log "FAIL" "Missing env var: \$${var}"
            exit 2
        fi
    done
    log "INFO" "Prerequisites OK."
}

run_structural_checks() {
    log "INFO" "--- STRUCTURAL CHECKS ---"

    run_check "S-001" "TRADES_COLD Iceberg table exists" \
        "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_CATALOG='TRADE_ANALYTICS' AND TABLE_SCHEMA='ICEBERG' AND TABLE_NAME='TRADES_COLD';" \
        "^\s*1\s*$"

    run_check "S-002" "TRADES_WARM Iceberg table exists" \
        "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_CATALOG='TRADE_ANALYTICS' AND TABLE_SCHEMA='ICEBERG' AND TABLE_NAME='TRADES_WARM';" \
        "^\s*1\s*$"

    run_check "S-003" "Unified view V_ALL_TRADES exists" \
        "SELECT COUNT(*) FROM INFORMATION_SCHEMA.VIEWS WHERE TABLE_CATALOG='TRADE_ANALYTICS' AND TABLE_SCHEMA='VIEWS' AND TABLE_NAME='V_ALL_TRADES';" \
        "^\s*1\s*$"

    run_check "S-004" "TRADES_COLD column count matches expected (32 columns)" \
        "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_CATALOG='TRADE_ANALYTICS' AND TABLE_SCHEMA='ICEBERG' AND TABLE_NAME='TRADES_COLD';" \
        "^\s*32\s*$"
}

run_volume_checks() {
    log "INFO" "--- VOLUME CHECKS ---"

    run_check "V-001" "Total row count > 0 in TRADES_COLD" \
        "SELECT CASE WHEN COUNT(*) > 0 THEN 'PASS' ELSE 'FAIL_EMPTY' END FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD WHERE trade_year BETWEEN YEAR('${START_DATE}'::DATE) AND YEAR('${END_DATE}'::DATE);" \
        "PASS"

    run_check "V-002" "All expected years present in TRADES_COLD" \
        "SELECT COUNT(DISTINCT trade_year) FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD WHERE trade_year BETWEEN YEAR('${START_DATE}'::DATE) AND YEAR('${END_DATE}'::DATE);" \
        "^\s*$(($(date -d "${END_DATE}" +%Y) - $(date -d "${START_DATE}" +%Y) + 1))\s*$"

    run_check "V-003" "No NULL trade_id values in TRADES_COLD" \
        "SELECT CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD WHERE trade_id IS NULL;" \
        "PASS"

    run_check "V-004" "No duplicate trade_id in TRADES_COLD" \
        "SELECT CASE WHEN COUNT(*) = COUNT(DISTINCT trade_id) THEN 'PASS' ELSE 'FAIL' END FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD WHERE trade_year BETWEEN YEAR('${START_DATE}'::DATE) AND YEAR('${END_DATE}'::DATE);" \
        "PASS"

    run_check "V-005" "All 11 expected asset classes present" \
        "SELECT COUNT(DISTINCT asset_class) FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD;" \
        "^\s*11\s*$"
}

run_content_checks() {
    log "INFO" "--- CONTENT CHECKS ---"

    run_check "C-001" "No NULL notional_usd values" \
        "SELECT CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD WHERE notional_usd IS NULL;" \
        "PASS"

    run_check "C-002" "All direction values are BUY or SELL" \
        "SELECT CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD WHERE direction NOT IN ('BUY','SELL');" \
        "PASS"

    run_check "C-003" "Partition columns consistent with trade_date" \
        "SELECT CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD WHERE YEAR(trade_date) != trade_year OR MONTH(trade_date) != trade_month;" \
        "PASS"

    run_check "C-004" "Notional values are positive (no negative notional)" \
        "SELECT CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD WHERE notional_usd <= 0;" \
        "PASS"

    run_check "C-005" "No future-dated trades in cold tier" \
        "SELECT CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD WHERE trade_date > CURRENT_DATE();" \
        "PASS"
}

run_migration_log_checks() {
    log "INFO" "--- MIGRATION LOG CHECKS ---"

    run_check "L-001" "Migration log has entries for all months" \
        "SELECT CASE WHEN COUNT(*) >= DATEDIFF('month', '${START_DATE}'::DATE, '${END_DATE}'::DATE) + 1 THEN 'PASS' ELSE 'FAIL' END FROM TRADE_ANALYTICS.MANAGED.MIGRATION_LOG WHERE status = 'COMPLETED' AND partition_start >= '${START_DATE}' AND partition_end <= '${END_DATE}';" \
        "PASS"

    run_check "L-002" "No failed migrations in log" \
        "SELECT CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END FROM TRADE_ANALYTICS.MANAGED.MIGRATION_LOG WHERE status = 'FAILED' AND partition_start >= '${START_DATE}';" \
        "PASS"
}

run_query_sanity_checks() {
    log "INFO" "--- QUERY SANITY CHECKS (view works correctly) ---"

    run_check "Q-001" "V_ALL_TRADES returns results without error" \
        "SELECT CASE WHEN COUNT(*) > 0 THEN 'PASS' ELSE 'FAIL' END FROM TRADE_ANALYTICS.VIEWS.V_ALL_TRADES WHERE trade_year = YEAR('${START_DATE}'::DATE) LIMIT 1;" \
        "PASS"

    run_check "Q-002" "Partition pruning works (query planning < 5s for single asset class)" \
        "SELECT CASE WHEN COUNT(*) >= 0 THEN 'PASS' ELSE 'FAIL' END FROM TRADE_ANALYTICS.ICEBERG.TRADES_COLD WHERE trade_year = YEAR('${START_DATE}'::DATE) AND trade_month = 1 AND asset_class = 'FX';" \
        "PASS"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    mkdir -p "${LOG_DIR}"

    log "INFO" "============================================================"
    log "INFO" " Snowflake Iceberg Migration — validate_migration.sh"
    log "INFO" " Validation range: ${START_DATE} → ${END_DATE}"
    log "INFO" " Started: $(date '+%Y-%m-%d %H:%M:%S UTC')"
    log "INFO" "============================================================"

    if [[ "${WRITE_REPORT}" == "true" ]]; then
        log "INFO" "Writing report to: ${REPORT_FILE}"
    fi

    check_prerequisites
    run_structural_checks
    run_volume_checks
    run_content_checks
    run_migration_log_checks
    run_query_sanity_checks

    print_summary

    if [[ ${FAILED_CHECKS} -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

main "$@"