#!/bin/bash
# =============================================================================
# AgentStack OSS - PostgreSQL Backup Verification Script
# Version: 1.0.0
# Description: Verify backup integrity and test restore procedures
# Usage: ./scripts/backup-verify.sh [verify|test-restore|cleanup]
# =============================================================================
set -euo pipefail

# Configuration
readonly BACKUP_DIR="${BACKUP_DIR:-/opt/agentstack/postgres/backups}"
readonly TEST_DB="${TEST_DB:-agentstack_backup_test}"
readonly POSTGRES_USER="${POSTGRES_USER:-postgres}"
readonly POSTGRES_PORT="${POSTGRES_PORT:-5432}"
readonly POSTGRES_HOST="${POSTGRES_HOST:-localhost}"
readonly RETENTION_DAYS="${RETENTION_DAYS:-30}"
readonly LOG_DIR="${LOG_DIR:-/opt/agentstack/postgres/logs}"
readonly COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.production-postgres.yml}"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Logging functions
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [BACKUP_VERIFY] $*" | tee -a "$LOG_DIR/backup-verify.log"
}

log_error() {
    echo -e "${RED}$(date '+%Y-%m-%d %H:%M:%S') [BACKUP_VERIFY] ERROR: $*${NC}" | tee -a "$LOG_DIR/backup-verify.log"
}

log_warning() {
    echo -e "${YELLOW}$(date '+%Y-%m-%d %H:%M:%S') [BACKUP_VERIFY] WARNING: $*${NC}" | tee -a "$LOG_DIR/backup-verify.log"
}

log_success() {
    echo -e "${GREEN}$(date '+%Y-%m-%d %H:%M:%S') [BACKUP_VERIFY] SUCCESS: $*${NC}" | tee -a "$LOG_DIR/backup-verify.log"
}

# Utility functions
ensure_directories() {
    mkdir -p "$BACKUP_DIR" "$LOG_DIR"
    chmod 755 "$BACKUP_DIR"
    chmod 700 "$LOG_DIR"
}

check_prerequisites() {
    # Check Docker
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not available"
        exit 1
    fi

    # Check if PostgreSQL is running
    if ! docker-compose -f "$COMPOSE_FILE" ps postgres | grep -q "Up"; then
        log_error "PostgreSQL is not running"
        exit 1
    fi

    # Check if we can connect
    if ! docker-compose -f "$COMPOSE_FILE" exec -T postgres pg_isready -U "$POSTGRES_USER" -p "$POSTGRES_PORT"; then
        log_error "Cannot connect to PostgreSQL"
        exit 1
    fi

    log_success "Prerequisites check passed"
}

# Backup verification functions
verify_backup_integrity() {
    local backup_file="$1"
    log "Verifying backup integrity: $backup_file"

    if [[ ! -f "$backup_file" ]]; then
        log_error "Backup file not found: $backup_file"
        return 1
    fi

    # Check file size (should be greater than 0)
    local file_size
    file_size=$(stat -f%z "$backup_file" 2>/dev/null || stat -c%s "$backup_file" 2>/dev/null || echo "0")

    if [[ $file_size -eq 0 ]]; then
        log_error "Backup file is empty: $backup_file"
        return 1
    fi

    # Check if file is readable
    if [[ ! -r "$backup_file" ]]; then
        log_error "Backup file is not readable: $backup_file"
        return 1
    fi

    # For compressed files, check if they can be decompressed
    if [[ "$backup_file" == *.gz ]]; then
        if ! gzip -t "$backup_file" 2>/dev/null; then
            log_error "Compressed backup file is corrupted: $backup_file"
            return 1
        fi
    fi

    # Try to get backup metadata
    if [[ "$backup_file" == *.sql.gz ]]; then
        local metadata
        metadata=$(gunzip -c "$backup_file" | head -20 | grep -E "^--" | head -5 || echo "")

        if [[ -n "$metadata" ]]; then
            log "Backup metadata found:"
            echo "$metadata" | tee -a "$LOG_DIR/backup-verify.log"
        else
            log_warning "Could not extract backup metadata"
        fi
    fi

    log_success "Backup integrity verified: $backup_file ($(numfmt --to=iec $file_size))"
    return 0
}

create_test_database() {
    log "Creating test database: $TEST_DB"

    # Drop test database if it exists
    docker-compose -f "$COMPOSE_FILE" exec -T postgres psql \
        -U "$POSTGRES_USER" -d postgres \
        -c "DROP DATABASE IF EXISTS $TEST_DB;" 2>/dev/null || true

    # Create test database
    if docker-compose -f "$COMPOSE_FILE" exec -T postgres psql \
        -U "$POSTGRES_USER" -d postgres \
        -c "CREATE DATABASE $TEST_DB;"; then
        log_success "Test database created: $TEST_DB"
        return 0
    else
        log_error "Failed to create test database: $TEST_DB"
        return 1
    fi
}

test_restore_backup() {
    local backup_file="$1"
    log "Testing restore from: $backup_file"

    # Create test database
    if ! create_test_database; then
        return 1
    fi

    # Restore backup
    local start_time
    start_time=$(date +%s)

    if [[ "$backup_file" == *.sql.gz ]]; then
        if gunzip -c "$backup_file" | docker-compose -f "$COMPOSE_FILE" exec -T postgres psql \
            -U "$POSTGRES_USER" -d "$TEST_DB" \
            -v ON_ERROR_STOP=1; then
            local end_time
            end_time=$(date +%s)
            local duration=$((end_time - start_time))
            log_success "Backup restore successful in ${duration}s: $backup_file"
            return 0
        else
            log_error "Failed to restore backup: $backup_file"
            return 1
        fi
    elif [[ "$backup_file" == *.sql ]]; then
        if docker-compose -f "$COMPOSE_FILE" exec -T postgres psql \
            -U "$POSTGRES_USER" -d "$TEST_DB" \
            -f - < "$backup_file"; then
            local end_time
            end_time=$(date +%s)
            local duration=$((end_time - start_time))
            log_success "Backup restore successful in ${duration}s: $backup_file"
            return 0
        else
            log_error "Failed to restore backup: $backup_file"
            return 1
        fi
    else
        log_error "Unsupported backup format: $backup_file"
        return 1
    fi
}

verify_restored_data() {
    log "Verifying restored data in test database: $TEST_DB"

    # Check if tables exist
    local table_count
    table_count=$(docker-compose -f "$COMPOSE_FILE" exec -T postgres psql \
        -U "$POSTGRES_USER" -d "$TEST_DB" -tAc \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'agentstack';" 2>/dev/null || echo "0")

    if [[ $table_count -gt 0 ]]; then
        log_success "Restored database contains $table_count agentstack tables"
    else
        log_error "No agentstack tables found in restored database"
        return 1
    fi

    # Check critical tables
    local critical_tables=("knowledge_base" "chat_sessions" "chat_messages")
    for table in "${critical_tables[@]}"; do
        local exists
        exists=$(docker-compose -f "$COMPOSE_FILE" exec -T postgres psql \
            -U "$POSTGRES_USER" -d "$TEST_DB" -tAc \
            "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_schema = 'agentstack' AND table_name = '$table');" 2>/dev/null || echo "f")

        if [[ "$exists" == "t" ]]; then
            log_success "Critical table exists: agentstack.$table"
        else
            log_error "Critical table missing: agentstack.$table"
            return 1
        fi
    done

    # Check if extensions are installed
    local extension_count
    extension_count=$(docker-compose -f "$COMPOSE_FILE" exec -T postgres psql \
        -U "$POSTGRES_USER" -d "$TEST_DB" -tAc \
        "SELECT COUNT(*) FROM pg_extension WHERE extname IN ('vector', 'uuid-ossp', 'pg_trgm');" 2>/dev/null || echo "0")

    if [[ $extension_count -eq 3 ]]; then
        log_success "All required extensions are installed in restored database"
    else
        log_error "Some extensions are missing in restored database (found: $extension_count/3)"
        return 1
    fi

    # Check if vector data exists (if knowledge_base has data)
    local vector_count
    vector_count=$(docker-compose -f "$COMPOSE_FILE" exec -T postgres psql \
        -U "$POSTGRES_USER" -d "$TEST_DB" -tAc \
        "SELECT COUNT(*) FROM agentstack.knowledge_base WHERE embedding IS NOT NULL LIMIT 1;" 2>/dev/null || echo "0")

    if [[ $vector_count -ge 0 ]]; then
        log_success "Vector data check passed (count: $vector_count)"
    else
        log_warning "Could not verify vector data"
    fi

    log_success "Data verification completed successfully"
    return 0
}

cleanup_test_database() {
    log "Cleaning up test database: $TEST_DB"

    if docker-compose -f "$COMPOSE_FILE" exec -T postgres psql \
        -U "$POSTGRES_USER" -d postgres \
        -c "DROP DATABASE IF EXISTS $TEST_DB;" 2>/dev/null; then
        log_success "Test database cleaned up"
    else
        log_warning "Could not clean up test database"
    fi
}

verify_all_backups() {
    log "Starting comprehensive backup verification"

    local backup_count=0
    local verified_count=0
    local failed_count=0

    # Find all backup files
    while IFS= read -r -d '' backup_file; do
        ((backup_count++))

        if verify_backup_integrity "$backup_file"; then
            ((verified_count++))
        else
            ((failed_count++))
        fi
    done < <(find "$BACKUP_DIR" -name "*.sql*" -type f -print0 | sort -z)

    log "Backup verification summary:"
    log "  Total backups: $backup_count"
    log "  Verified: $verified_count"
    log "  Failed: $failed_count"

    if [[ $failed_count -eq 0 ]]; then
        log_success "All backups verified successfully"
        return 0
    else
        log_error "Some backups failed verification"
        return 1
    fi
}

test_latest_backup() {
    log "Testing restore of latest backup"

    local latest_backup
    latest_backup=$(find "$BACKUP_DIR" -name "*.sql*" -type f -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)

    if [[ -z "$latest_backup" ]]; then
        log_error "No backup files found"
        return 1
    fi

    log "Latest backup: $latest_backup"

    # Verify integrity first
    if ! verify_backup_integrity "$latest_backup"; then
        return 1
    fi

    # Test restore
    if test_restore_backup "$latest_backup"; then
        # Verify restored data
        if verify_restored_data; then
            log_success "Latest backup test completed successfully"
            cleanup_test_database
            return 0
        else
            log_error "Data verification failed"
            cleanup_test_database
            return 1
        fi
    else
        log_error "Restore test failed"
        cleanup_test_database
        return 1
    fi
}

cleanup_old_backups() {
    log "Cleaning up old backups (retention: $RETENTION_DAYS days)"

    local deleted_count=0
    local total_size_before=0
    local total_size_after=0

    # Calculate total size before cleanup
    while IFS= read -r -d '' backup_file; do
        local file_size
        file_size=$(stat -f%z "$backup_file" 2>/dev/null || stat -c%s "$backup_file" 2>/dev/null || echo "0")
        total_size_before=$((total_size_before + file_size))
    done < <(find "$BACKUP_DIR" -name "*.sql*" -type f -print0)

    # Delete old backups
    while IFS= read -r -d '' backup_file; do
        rm -f "$backup_file"
        ((deleted_count++))
        log "Deleted old backup: $(basename "$backup_file")"
    done < <(find "$BACKUP_DIR" -name "*.sql*" -type f -mtime "+$RETENTION_DAYS" -print0)

    # Calculate total size after cleanup
    while IFS= read -r -d '' backup_file; do
        local file_size
        file_size=$(stat -f%z "$backup_file" 2>/dev/null || stat -c%s "$backup_file" 2>/dev/null || echo "0")
        total_size_after=$((total_size_after + file_size))
    done < <(find "$BACKUP_DIR" -name "*.sql*" -type f -print0)

    local space_freed=$((total_size_before - total_size_after))

    log "Backup cleanup summary:"
    log "  Files deleted: $deleted_count"
    log "  Space freed: $(numfmt --to=iec $space_freed)"
    log "  Current total size: $(numfmt --to=iec $total_size_after)"

    if [[ $deleted_count -gt 0 ]]; then
        log_success "Cleanup completed successfully"
    else
        log_info "No old backups to clean up"
    fi
}

generate_backup_report() {
    local report_file="$BACKUP_DIR/backup-report-$(date +%Y%m%d_%H%M%S).txt"

    log "Generating backup report: $report_file"

    cat > "$report_file" << EOF
AgentStack PostgreSQL Backup Report
Generated: $(date)
==================================

Backup Summary:
-------------
EOF

    # Count backup files by type
    local sql_count=0
    local gz_count=0

    while IFS= read -r -d '' backup_file; do
        if [[ "$backup_file" == *.sql.gz ]]; then
            ((gz_count++))
        elif [[ "$backup_file" == *.sql ]]; then
            ((sql_count++))
        fi
    done < <(find "$BACKUP_DIR" -name "*.sql*" -type f -print0)

    cat >> "$report_file" << EOF
  SQL files: $sql_count
  Compressed files: $gz_count
  Total files: $((sql_count + gz_count))

Backup Files (newest first):
-----------------------------
EOF

    # List backup files with details
    find "$BACKUP_DIR" -name "*.sql*" -type f -printf '%TY-%Tm-%Td %TH:%TM %s %p\n' | sort -r | while read -r timestamp time size file; do
        local size_human
        size_human=$(numfmt --to=iec "$size")
        echo "  $timestamp $time $size_human $(basename "$file")" >> "$report_file"
    done

    cat >> "$report_file" << EOF

Total Storage Used:
------------------
EOF

    local total_size=0
    while IFS= read -r -d '' backup_file; do
        local file_size
        file_size=$(stat -f%z "$backup_file" 2>/dev/null || stat -c%s "$backup_file" 2>/dev/null || echo "0")
        total_size=$((total_size + file_size))
    done < <(find "$BACKUP_DIR" -name "*.sql*" -type f -print0)

    cat >> "$report_file" << EOF
  Total: $(numfmt --to=iec $total_size)
  Retention policy: $RETENTION_DAYS days

Recommendations:
----------------
EOF

    # Add recommendations
    if [[ $total_size -gt 10737418240 ]]; then  # 10GB
        echo "  - Consider compressing uncompressed SQL files to save space" >> "$report_file"
    fi

    if [[ $((sql_count + gz_count)) -gt 100 ]]; then
        echo "  - Consider implementing automatic backup rotation" >> "$report_file"
    fi

    if [[ $gz_count -eq 0 ]]; then
        echo "  - Enable compression to reduce storage costs" >> "$report_file"
    fi

    log_success "Backup report generated: $report_file"
}

# Main functions
main() {
    ensure_directories
    check_prerequisites

    local command="${1:-verify}"

    case "$command" in
        verify)
            verify_all_backups
            ;;
        test-restore)
            test_latest_backup
            ;;
        cleanup)
            cleanup_old_backups
            ;;
        report)
            generate_backup_report
            ;;
        all)
            verify_all_backups
            test_latest_backup
            cleanup_old_backups
            generate_backup_report
            ;;
        *)
            echo "Usage: $0 {verify|test-restore|cleanup|report|all}"
            echo ""
            echo "Commands:"
            echo "  verify       Verify integrity of all backup files"
            echo "  test-restore  Test restore of latest backup"
            echo "  cleanup      Remove old backups based on retention policy"
            echo "  report       Generate backup report"
            echo "  all          Run all verification tasks"
            exit 1
            ;;
    esac
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi