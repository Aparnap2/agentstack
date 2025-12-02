#!/bin/bash
# =============================================================================
# AgentStack OSS - pREST Production Entrypoint Script
# Version: 2.0.0
# Description: Production-ready container startup with health checks and validation
# =============================================================================

set -euo pipefail

# Configuration
PREST_CONFIG_PATH="${PREST_CONFIG_PATH:-/etc/prest}"
PREST_LOG_PATH="${PREST_LOG_PATH:-/var/log/prest}"
PREST_CACHE_PATH="${PREST_CACHE_PATH:-/var/cache/prest}"
PREST_SSL_PATH="${PREST_SSL_PATH:-/opt/prest/ssl}"
PREST_PLUGIN_PATH="${PREST_PLUGIN_PATH:-/opt/prest/plugins}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-60}"
GRACEFUL_SHUTDOWN_TIMEOUT="${GRACEFUL_SHUTDOWN_TIMEOUT:-30}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date -u '+%Y-%m-%d %H:%M:%S')

    case "$level" in
        "ERROR") echo -e "${RED}[ERROR]${NC} [$timestamp] $message" | tee -a "$PREST_LOG_PATH/startup.log" >&2 ;;
        "WARN")  echo -e "${YELLOW}[WARN]${NC}  [$timestamp] $message" | tee -a "$PREST_LOG_PATH/startup.log" ;;
        "INFO")  echo -e "${GREEN}[INFO]${NC}  [$timestamp] $message" | tee -a "$PREST_LOG_PATH/startup.log" ;;
        "DEBUG") echo -e "${BLUE}[DEBUG]${NC} [$timestamp] $message" | tee -a "$PREST_LOG_PATH/startup.log" ;;
    esac
}

# Error handling
error_exit() {
    log "ERROR" "$1"
    exit 1
}

# Cleanup function for graceful shutdown
cleanup() {
    log "INFO" "Received shutdown signal, initiating graceful shutdown..."

    # Send SIGTERM to the main process
    if [ -n "$PREST_PID" ]; then
        log "INFO" "Sending SIGTERM to pREST process (PID: $PREST_PID)"
        kill -TERM "$PREST_PID" 2>/dev/null || true

        # Wait for graceful shutdown or force kill
        local count=0
        while kill -0 "$PREST_PID" 2>/dev/null && [ $count -lt $GRACEFUL_SHUTDOWN_TIMEOUT ]; do
            sleep 1
            count=$((count + 1))
        done

        if kill -0 "$PREST_PID" 2>/dev/null; then
            log "WARN" "pREST did not shut down gracefully, forcing..."
            kill -KILL "$PREST_PID" 2>/dev/null || true
        fi
    fi

    log "INFO" "Graceful shutdown completed"
    exit 0
}

# Setup signal handlers
trap cleanup SIGTERM SIGINT SIGQUIT

# Validate environment variables
validate_environment() {
    log "INFO" "Validating environment variables..."

    local required_vars=(
        "PREST_PG_HOST"
        "PREST_PG_PORT"
        "PREST_PG_USER"
        "PREST_PG_PASS"
        "PREST_PG_DATABASE"
        "PREST_JWT_KEY"
    )

    local optional_vars=(
        "PREST_SSL_MODE"
        "REDIS_HOST"
        "REDIS_PASSWORD"
        "OTEL_ENABLED"
        "OTEL_EXPORTER_OTLP_ENDPOINT"
    )

    # Check required variables
    for var in "${required_vars[@]}"; do
        if [ -z "${!var:-}" ]; then
            error_exit "Required environment variable $var is not set"
        fi
    done

    # Log optional variables status
    for var in "${optional_vars[@]}"; do
        if [ -n "${!var:-}" ]; then
            log "INFO" "$var is set"
        else
            log "DEBUG" "$var is not set (optional)"
        fi
    done

    log "INFO" "Environment validation completed"
}

# Verify SSL certificates
verify_ssl_certificates() {
    log "INFO" "Verifying SSL certificates..."

    if [ "$PREST_SSL_MODE" = "require" ] || [ "$PREST_SSL_MODE" = "verify-ca" ] || [ "$PREST_SSL_MODE" = "verify-full" ]; then
        local cert_file="$PREST_SSL_PATH/client.crt"
        local key_file="$PREST_SSL_PATH/client.key"
        local ca_file="$PREST_SSL_PATH/ca.crt"

        if [ ! -f "$cert_file" ]; then
            error_exit "SSL certificate file not found: $cert_file"
        fi

        if [ ! -f "$key_file" ]; then
            error_exit "SSL key file not found: $key_file"
        fi

        if [ ! -f "$ca_file" ]; then
            error_exit "SSL CA file not found: $ca_file"
        fi

        # Verify certificate
        if ! openssl x509 -in "$cert_file" -text -noout >/dev/null 2>&1; then
            error_exit "Invalid SSL certificate: $cert_file"
        fi

        # Verify key matches certificate
        local cert_modulus=$(openssl x509 -noout -modulus -in "$cert_file" 2>/dev/null | openssl md5)
        local key_modulus=$(openssl rsa -noout -modulus -in "$key_file" 2>/dev/null | openssl md5)

        if [ "$cert_modulus" != "$key_modulus" ]; then
            error_exit "SSL certificate and key do not match"
        fi

        log "INFO" "SSL certificates verified successfully"
    else
        log "INFO" "SSL verification skipped (mode: $PREST_SSL_MODE)"
    fi
}

# Validate configuration files
validate_configuration() {
    log "INFO" "Validating configuration files..."

    local config_file="$PREST_CONFIG_PATH/prest.toml"

    if [ ! -f "$config_file" ]; then
        error_exit "Configuration file not found: $config_file"
    fi

    # Basic TOML validation
    if ! command -v toml >/dev/null 2>&1; then
        log "WARN" "toml parser not available, skipping configuration validation"
    else
        if ! toml -json "$config_file" >/dev/null 2>&1; then
            error_exit "Invalid TOML configuration: $config_file"
        fi
        log "INFO" "Configuration file validation passed"
    fi

    # Validate plugin directory
    if [ ! -d "$PREST_PLUGIN_PATH" ]; then
        log "WARN" "Plugin directory not found: $PREST_PLUGIN_PATH"
    else
        log "INFO" "Plugin directory found: $PREST_PLUGIN_PATH"
    fi
}

# Wait for dependencies
wait_for_dependencies() {
    log "INFO" "Waiting for dependencies..."

    # Wait for PostgreSQL via PgBouncer
    if [ -n "${PREST_PG_HOST:-}" ] && [ -n "${PREST_PG_PORT:-}" ]; then
        log "INFO" "Waiting for PostgreSQL at ${PREST_PG_HOST}:${PREST_PG_PORT}..."

        if ! timeout "$WAIT_TIMEOUT" /usr/local/bin/wait-for-it.sh "${PREST_PG_HOST}:${PREST_PG_PORT}" --strict --timeout=30; then
            error_exit "PostgreSQL not available at ${PREST_PG_HOST}:${PREST_PG_PORT}"
        fi

        # Test database connection
        log "INFO" "Testing database connection..."
        if ! timeout 10 psql "postgresql://${PREST_PG_USER}:${PREST_PG_PASS}@${PREST_PG_HOST}:${PREST_PG_PORT}/${PREST_PG_DATABASE}?sslmode=${PREST_SSL_MODE:-prefer}" -c "SELECT 1;" >/dev/null 2>&1; then
            error_exit "Database connection test failed"
        fi

        log "INFO" "Database connection verified"
    fi

    # Wait for Redis (if cache is enabled)
    if [ "${PREST_CACHE_ENABLED:-true}" = "true" ] && [ -n "${REDIS_HOST:-}" ] && [ -n "${REDIS_PORT:-6379}" ]; then
        log "INFO" "Waiting for Redis at ${REDIS_HOST}:${REDIS_PORT}..."

        if ! timeout "$WAIT_TIMEOUT" /usr/local/bin/wait-for-it.sh "${REDIS_HOST}:${REDIS_PORT}" --strict --timeout=10; then
            log "WARN" "Redis not available, continuing without cache"
        else
            # Test Redis connection
            if [ -n "${REDIS_PASSWORD:-}" ]; then
                REDIS_CMD="redis-cli -h ${REDIS_HOST} -p ${REDIS_PORT} -a ${REDIS_PASSWORD}"
            else
                REDIS_CMD="redis-cli -h ${REDIS_HOST} -p ${REDIS_PORT}"
            fi

            if ! timeout 10 $REDIS_CMD ping >/dev/null 2>&1; then
                log "WARN" "Redis connection test failed, continuing without cache"
            else
                log "INFO" "Redis connection verified"
            fi
        fi
    fi

    log "INFO" "Dependency check completed"
}

# Setup logging
setup_logging() {
    log "INFO" "Setting up logging..."

    # Create log directories
    mkdir -p "$PREST_LOG_PATH"

    # Set proper permissions
    chmod 755 "$PREST_LOG_PATH"

    # Create log file if it doesn't exist
    touch "$PREST_LOG_PATH/prest.log"
    chmod 644 "$PREST_LOG_PATH/prest.log"

    # Setup log rotation if logrotate is available
    if command -v logrotate >/dev/null 2>&1; then
        cat > /etc/logrotate.d/prest << EOF
$PREST_LOG_PATH/prest.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 644 prest prest
    postrotate
        # Send USR1 signal to pREST to reopen logs
        if [ -f /var/run/prest.pid ]; then
            kill -USR1 \$(cat /var/run/prest.pid) 2>/dev/null || true
        fi
    endscript
}
EOF
        log "INFO" "Log rotation configured"
    fi

    log "INFO" "Logging setup completed"
}

# Setup cache directory
setup_cache() {
    log "INFO" "Setting up cache directory..."

    mkdir -p "$PREST_CACHE_PATH"
    chmod 755 "$PREST_CACHE_PATH"

    log "INFO" "Cache directory setup completed"
}

# Validate database schema
validate_database_schema() {
    log "INFO" "Validating database schema..."

    # Check if database exists and is accessible
    if ! timeout 30 psql "postgresql://${PREST_PG_USER}:${PREST_PG_PASS}@${PREST_PG_HOST}:${PREST_PG_PORT}/${PREST_PG_DATABASE}?sslmode=${PREST_SSL_MODE:-prefer}" -c "\dt" >/dev/null 2>&1; then
        error_exit "Database schema validation failed"
    fi

    # Check for required tables (basic validation)
    local required_tables=("schema_migrations")
    for table in "${required_tables[@]}"; do
        if timeout 10 psql "postgresql://${PREST_PG_USER}:${PREST_PG_PASS}@${PREST_PG_HOST}:${PREST_PG_PORT}/${PREST_PG_DATABASE}?sslmode=${PREST_SSL_MODE:-prefer}" -c "\dt $table" | grep -q "$table"; then
            log "INFO" "Required table $table found"
        else
            log "WARN" "Required table $table not found"
        fi
    done

    log "INFO" "Database schema validation completed"
}

# Performance tuning
apply_performance_tuning() {
    log "INFO" "Applying performance tuning..."

    # Set ulimit for file descriptors
    if [ -n "${PREST_MAX_OPEN_FILES:-}" ]; then
        ulimit -n "$PREST_MAX_OPEN_FILES" || log "WARN" "Failed to set ulimit for open files"
    fi

    # Set GOMAXPROCS
    if [ -n "${GOMAXPROCS:-}" ]; then
        export GOMAXPROCS="$GOMAXPROCS"
        log "INFO" "GOMAXPROCS set to $GOMAXPROCS"
    fi

    # Set memory limit
    if [ -n "${GOMEMLIMIT:-}" ]; then
        export GOMEMLIMIT="$GOMEMLIMIT"
        log "INFO" "GOMEMLIMIT set to $GOMEMLIMIT"
    fi

    log "INFO" "Performance tuning completed"
}

# Run security checks
run_security_checks() {
    log "INFO" "Running security checks..."

    # Check for exposed secrets in environment
    local sensitive_patterns=("password.*=" "secret.*=" "key.*=" "token.*=")
    for pattern in "${sensitive_patterns[@]}"; do
        if env | grep -i "$pattern" | grep -v "PREST_"; then
            log "WARN" "Potential sensitive data found in environment variables"
        fi
    done

    # Check file permissions
    find "$PREST_CONFIG_PATH" -type f -name "*.toml" -exec chmod 600 {} \;
    find "$PREST_SSL_PATH" -type f -name "*.key" -exec chmod 600 {} \;
    find "$PREST_SSL_PATH" -type f -name "*.crt" -exec chmod 644 {} \;

    log "INFO" "Security checks completed"
}

# Start pREST
start_prest() {
    log "INFO" "Starting pREST..."

    # Create PID file directory
    mkdir -p /var/run
    echo $$ > /var/run/prest.pid

    # Set default configuration if not provided
    local config_args=()
    if [ -f "$PREST_CONFIG_PATH/prest.toml" ]; then
        config_args+=("-config" "$PREST_CONFIG_PATH/prest.toml")
    fi

    # Build command
    local cmd="/usr/local/bin/prestd ${config_args[*]}"

    log "INFO" "Executing: $cmd"

    # Start pREST in background
    exec $cmd &
    PREST_PID=$!

    # Wait for pREST to be ready
    local wait_count=0
    local max_wait=60

    while [ $wait_count -lt $max_wait ]; do
        if curl -f -s http://localhost:3000/health >/dev/null 2>&1; then
            log "INFO" "pREST is ready and listening on port 3000"
            break
        fi

        if ! kill -0 "$PREST_PID" 2>/dev/null; then
            error_exit "pREST process died during startup"
        fi

        sleep 1
        wait_count=$((wait_count + 1))
    done

    if [ $wait_count -ge $max_wait ]; then
        error_exit "pREST failed to become ready within $max_wait seconds"
    fi

    log "INFO" "pREST started successfully with PID: $PREST_PID"
}

# Main startup sequence
main() {
    log "INFO" "Starting AgentStack pREST container..."
    log "INFO" "Version: 2.0.0"
    log "INFO" "Environment: ${ENVIRONMENT:-production}"

    # Run all validation and setup steps
    validate_environment
    verify_ssl_certificates
    validate_configuration
    setup_logging
    setup_cache
    apply_performance_tuning
    run_security_checks
    wait_for_dependencies
    validate_database_schema

    # Start the application
    start_prest

    # Wait for the main process
    wait "$PREST_PID"

    # Clean up
    rm -f /var/run/prest.pid

    log "INFO" "pREST container shutdown completed"
}

# Execute main function
main "$@"