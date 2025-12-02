#!/bin/bash
# =============================================================================
# AgentStack OSS - PostgreSQL Production Health Check
# Version: 1.0.0
# Description: Comprehensive health monitoring for PostgreSQL container
# Usage: Used by Docker HEALTHCHECK directive
# =============================================================================

set -euo pipefail

# Configuration
readonly PGDATA="${PGDATA:-/var/lib/postgresql/data}"
readonly PGUSER="${POSTGRES_USER:-postgres}"
readonly PGDATABASE="${POSTGRES_DB:-agentstack}"
readonly PGPORT="${PGPORT:-5432}"
readonly SOCKET_DIR="/var/run/postgresql"
readonly LOG_FILE="/tmp/health-check.log"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [HEALTH_CHECK] $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}$(date '+%Y-%m-%d %H:%M:%S') [HEALTH_CHECK] ERROR: $*${NC}" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}$(date '+%Y-%m-%d %H:%M:%S') [HEALTH_CHECK] WARNING: $*${NC}" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}$(date '+%Y-%m-%d %H:%M:%S') [HEALTH_CHECK] SUCCESS: $*${NC}" | tee -a "$LOG_FILE"
}

# Check 1: PostgreSQL process is running
check_postgres_process() {
    if ! pgrep -x "postgres" > /dev/null; then
        log_error "PostgreSQL process is not running"
        return 1
    fi
    log_success "PostgreSQL process is running"
    return 0
}

# Check 2: Socket file exists and has correct permissions
check_socket() {
    if [[ ! -S "${SOCKET_DIR}/.s.PGSQL.${PGPORT}" ]]; then
        log_error "PostgreSQL socket file not found at ${SOCKET_DIR}/.s.PGSQL.${PGPORT}"
        return 1
    fi

    if [[ ! -r "${SOCKET_DIR}/.s.PGSQL.${PGPORT}" ]]; then
        log_error "PostgreSQL socket file is not readable"
        return 1
    fi

    log_success "PostgreSQL socket file is accessible"
    return 0
}

# Check 3: Database connection and basic query
check_database_connection() {
    local connection_test
    connection_test=$(psql -U "$PGUSER" -d "$PGDATABASE" -p "$PGPORT" -tAc "SELECT 1;" 2>/dev/null || echo "")

    if [[ "$connection_test" != "1" ]]; then
        log_error "Cannot connect to database or execute basic query"
        return 1
    fi

    log_success "Database connection and basic query successful"
    return 0
}

# Check 4: Essential extensions are available
check_extensions() {
    local extensions=("vector" "uuid-ossp" "pg_trgm")
    local missing_extensions=()

    for ext in "${extensions[@]}"; do
        if ! psql -U "$PGUSER" -d "$PGDATABASE" -tAc "SELECT 1 FROM pg_extension WHERE extname = '$ext';" | grep -q "1"; then
            missing_extensions+=("$ext")
        fi
    done

    if [[ ${#missing_extensions[@]} -gt 0 ]]; then
        log_error "Missing required extensions: ${missing_extensions[*]}"
        return 1
    fi

    log_success "All required extensions are available"
    return 0
}

# Check 5: Vector similarity search functionality
check_vector_functionality() {
    local vector_test
    vector_test=$(psql -U "$PGUSER" -d "$PGDATABASE" -tAc "
        SELECT COUNT(*) > 0
        FROM (
            SELECT 1 as id, '[0.1,0.2,0.3]'::vector(3) as embedding
        ) test_data
        WHERE test_data.embedding IS NOT NULL;" 2>/dev/null || echo "")

    if [[ "$vector_test" != "t" ]]; then
        log_error "Vector functionality test failed"
        return 1
    fi

    log_success "Vector functionality test successful"
    return 0
}

# Check 6: Database size and disk space
check_disk_space() {
    local db_size
    db_size=$(psql -U "$PGUSER" -d "$PGDATABASE" -tAc "SELECT pg_size_pretty(pg_database_size('$PGDATABASE'));" 2>/dev/null || echo "")

    if [[ -z "$db_size" ]]; then
        log_error "Cannot determine database size"
        return 1
    fi

    local available_space
    available_space=$(df -h "$PGDATA" | awk 'NR==2 {print $4}' || echo "")

    if [[ -z "$available_space" ]]; then
        log_error "Cannot determine available disk space"
        return 1
    fi

    log_success "Database size: $db_size, Available space: $available_space"
    return 0
}

# Check 7: Active connections
check_connections() {
    local active_connections
    active_connections=$(psql -U "$PGUSER" -d "$PGDATABASE" -tAc "SELECT count(*) FROM pg_stat_activity WHERE state = 'active';" 2>/dev/null || echo "")

    if [[ -z "$active_connections" ]]; then
        log_error "Cannot determine active connections"
        return 1
    fi

    local max_connections
    max_connections=$(psql -U "$PGUSER" -d "$PGDATABASE" -tAc "SHOW max_connections;" 2>/dev/null || echo "")

    log_success "Active connections: $active_connections/$max_connections"
    return 0
}

# Check 8: WAL and replication status (if configured)
check_wal_status() {
    local wal_status
    wal_status=$(psql -U "$PGUSER" -d "$PGDATABASE" -tAc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "")

    if [[ "$wal_status" == "t" ]]; then
        log_success "Database is in recovery mode (replica)"
    else
        log_success "Database is in primary mode"
    fi

    return 0
}

# Main health check execution
main() {
    log "Starting PostgreSQL health check..."

    local checks=(
        "check_postgres_process"
        "check_socket"
        "check_database_connection"
        "check_extensions"
        "check_vector_functionality"
        "check_disk_space"
        "check_connections"
        "check_wal_status"
    )

    local failed_checks=0
    local total_checks=${#checks[@]}

    for check in "${checks[@]}"; do
        if ! $check; then
            ((failed_checks++))
        fi
    done

    local success_checks=$((total_checks - failed_checks))

    if [[ $failed_checks -eq 0 ]]; then
        log_success "All health checks passed ($success_checks/$total_checks)"
        exit 0
    else
        log_error "Health checks failed ($success_checks/$total_checks passed, $failed_checks failed)"
        exit 1
    fi
}

# Execute main function
main "$@"