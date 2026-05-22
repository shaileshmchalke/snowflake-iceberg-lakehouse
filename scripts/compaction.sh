#!/usr/bin/env bash
# =============================================================================
# FILE: scripts/compaction.sh
# PURPOSE: Run Iceberg FILE_COMPACTION after migration to merge small Parquet
#          files into optimal 512MB-1GB target size.
#
# WHY THIS IS NEEDED:
#   Per-month migration creates many small Parquet files per partition.
#   Small files hurt scan performance — Snowflake opens each file separately.
#   Compaction merges them. See ADR-003 for target file size rationale.
#
# WHEN TO RUN:
#   After migrate_table.sh completes ALL 12 months for a given year.
#   Do NOT run while migration is still writing to the same year.
#
# USAGE:
#   ./scripts/compaction.sh --year 2021
#   ./scripts/compaction.sh --year 2021 --year 2022 --year 2023
#   ./scripts/compaction.sh --year 2021 --table TRADES_WARM
#
# COST: ~10-15 Snowflake credits per year-partition on MEDIUM warehouse.
#       Run during off-peak hours (02:00-06:00 UTC).
#
# PREREQUISITES:
#   export SNOWFLAKE_ACCOUNT="your-account.us-east-1"
#   export SNOWFLAKE_USER="your_user"
#   export SNOWSQL_PWD="your_password"
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/../logs"
TARGET_TABLE="TRADES_COLD"
YEARS=()

GREEN='\033[0;32m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'

log() {
    local level="$1"; shift
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    case "$level" in
        PASS) echo -e "${GREEN}[${ts}][PASS] $*${NC}" ;;
        FAIL) echo -e "${RED}[${ts}][FAIL] $*${NC}" ;;
        INFO) echo -e "${BLUE}[${ts}][INFO] $*${NC}" ;;
    esac
}

usage() {
    echo "Usage: $0 --year YEAR [--year YEAR ...] [--table TABLE]"
    echo "  --year  YEAR    Year partition to compact (repeat for multiple)"
    echo "  --table TABLE   Iceberg table name (default: TRADES_COLD)"
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --year)  YEARS+=("$2");        shift 2 ;;
        --table) TARGET_TABLE="$2";    shift 2 ;;
        --help)  usage ;;
        *)       log "FAIL" "Unknown option: $1"; usage ;;
    esac
done

[[ ${#YEARS[@]} -eq 0 ]] && { log "FAIL" "--year is required."; usage; }

# Validate environment variables
for var in SNOWFLAKE_ACCOUNT SNOWFLAKE_USER SNOWSQL_PWD; do
    if [[ -z "${!var:-}" ]]; then
        log "FAIL" "Required env var not set: \$${var}"
        exit 1
    fi
done

mkdir -p "${LOG_DIR}"

# Execute SQL via SnowSQL (uses SNOWSQL_PWD env var — no --password flag)
run_snowsql() {
    local sql="$1"
    snowsql \
        --accountname   "${SNOWFLAKE_ACCOUNT}" \
        --username      "${SNOWFLAKE_USER}" \
        --rolename      ICEBERG_ADMIN \
        --warehousename TRADE_COLD_WH \
        --option        output_format=plain \
        --option        friendly=false \
        --query         "${sql}"
}

compact_year() {
    local year="$1"
    local table="TRADE_ANALYTICS.ICEBERG.${TARGET_TABLE}"
    local logfile="${LOG_DIR}/compaction_${TARGET_TABLE}_${year}_$(date +%Y%m%d_%H%M%S).log"

    log "INFO" "━━━━ Starting compaction: ${table} | year=${year} ━━━━"
    log "INFO" "Log file: ${logfile}"

    # Pre-compaction: record table info
    log "INFO" "Pre-compaction table information:"
    run_snowsql \
        "SELECT SYSTEM\$GET_ICEBERG_TABLE_INFORMATION('${table}');" \
        | tee -a "${logfile}"

    # Execute compaction
    local start_ts; start_ts=$(date +%s)
    log "INFO" "Executing FILE_COMPACTION (this may take 15-30 minutes)..."

    run_snowsql \
        "ALTER ICEBERG TABLE ${table}
             EXECUTE FILE_COMPACTION
             WHERE trade_year = ${year};" \
        | tee -a "${logfile}"

    local elapsed=$(( $(date +%s) - start_ts ))
    log "PASS" "Compaction complete — elapsed: ${elapsed}s"

    # Post-compaction: record updated table info
    log "INFO" "Post-compaction table information:"
    run_snowsql \
        "SELECT SYSTEM\$GET_ICEBERG_TABLE_INFORMATION('${table}');" \
        | tee -a "${logfile}"

    log "PASS" "━━━━ Done: ${table} year=${year} | log: ${logfile} ━━━━"
}

# Main execution
log "INFO" "=== Iceberg Compaction Script ==="
log "INFO" "Table : TRADE_ANALYTICS.ICEBERG.${TARGET_TABLE}"
log "INFO" "Years : ${YEARS[*]}"
echo ""

for year in "${YEARS[@]}"; do
    compact_year "${year}"
    echo ""
done

log "PASS" "All compaction runs complete."
log "INFO" "Review logs in: ${LOG_DIR}/"