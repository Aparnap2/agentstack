#!/bin/bash
# =============================================================================
# AgentStack OSS - PostgreSQL WAL Archive Script
# Version: 1.0.0
# Description: Archive WAL files for point-in-time recovery
# Usage: Called automatically by PostgreSQL archive_command
# =============================================================================
set -euo pipefail

# Configuration
readonly WAL_ARCHIVE_DIR="${WAL_ARCHIVE_DIR:-/opt/agentstack/postgres/wal_archive}"
readonly BACKUP_DIR="${BACKUP_DIR:-/opt/agentstack/postgres/backups}"
readonly WAL_FILE="$1"
readonly WAL_NAME="$2"
readonly LOG_DIR="${LOG_DIR:-/var/log/agentstack/postgres}"
readonly MAX_WAL_FILES="${MAX_WAL_FILES:-1000}"
readonly COMPRESS_WAL="${COMPRESS_WAL:-true}"

# Ensure directories exist
mkdir -p "$WAL_ARCHIVE_DIR" "$BACKUP_DIR" "$LOG_DIR"

# Function for logging
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [WAL_ARCHIVE] $*" | tee -a "$LOG_DIR/wal-archive.log"
}

log_error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [WAL_ARCHIVE] ERROR: $*" | tee -a "$LOG_DIR/wal-archive.log" >&2
}

# Check if WAL file exists
if [[ ! -f "$WAL_FILE" ]]; then
    log_error "WAL file not found: $WAL_FILE"
    exit 1
fi

# Archive the WAL file
ARCHIVE_PATH="$WAL_ARCHIVE_DIR/$WAL_NAME"

if cp "$WAL_FILE" "$ARCHIVE_PATH"; then
    log "Archived WAL file: $WAL_NAME"

    # Compress if enabled
    if [[ "$COMPRESS_WAL" == "true" ]]; then
        gzip -f "$ARCHIVE_PATH"
        log "Compressed WAL file: $WAL_NAME.gz"
    fi

    # Cleanup old WAL files
    find "$WAL_ARCHIVE_DIR" -name "*.gz" -type f | sort -r | tail -n +$((MAX_WAL_FILES + 1)) | xargs rm -f

    log "WAL archive completed successfully"
    exit 0
else
    log_error "Failed to archive WAL file: $WAL_NAME"
    exit 1
fi