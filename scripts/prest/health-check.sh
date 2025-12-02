#!/bin/bash
# =============================================================================
# AgentStack OSS - pREST Health Check Script
# Version: 2.0.0
# Description: Comprehensive health checks for pREST service
# =============================================================================

set -euo pipefail

# Configuration
PREST_HOST="${PREST_HOST:-localhost}"
PREST_PORT="${PREST_PORT:-3000}"
PREST_SCHEME="${PREST_SCHEME:-http}"
TIMEOUT="${HEALTH_CHECK_TIMEOUT:-10}"
RETRY_COUNT="${HEALTH_CHECK_RETRY_COUNT:-3}"
RETRY_DELAY="${HEALTH_CHECK_RETRY_DELAY:-2}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Health check URL
HEALTH_URL="${PREST_SCHEME}://${PREST_HOST}:${PREST_PORT}/health"
DETAILED_HEALTH_URL="${PREST_SCHEME}://${PREST_HOST}:${PREST_PORT}/health/detailed"
METRICS_URL="${PREST_SCHEME}://${PREST_HOST}:${PREST_PORT}/metrics"

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date -u '+%Y-%m-%d %H:%M:%S')

    case "$level" in
        "ERROR") echo -e "${RED}[ERROR]${NC} [$timestamp] $message" >&2 ;;
        "WARN")  echo -e "${YELLOW}[WARN]${NC}  [$timestamp] $message" ;;
        "INFO")  echo -e "${GREEN}[INFO]${NC}  [$timestamp] $message" ;;
        "DEBUG") echo -e "${BLUE}[DEBUG]${NC} [$timestamp] $message" ;;
    esac
}

# HTTP request function
http_request() {
    local url="$1"
    local method="${2:-GET}"
    local timeout="$3"
    local expected_status="${4:-200}"

    local curl_cmd="curl -s -w '%{http_code}' -o /dev/null --max-time '$timeout' -X '$method'"

    # Add SSL options if HTTPS
    if [[ "$url" == https://* ]]; then
        curl_cmd="$curl_cmd -k --connect-timeout 5"
    fi

    local status_code
    status_code=$(eval "$curl_cmd '$url'" 2>/dev/null || echo "000")

    if [ "$status_code" = "$expected_status" ]; then
        return 0
    else
        log "DEBUG" "HTTP $method $url returned $status_code (expected $expected_status)"
        return 1
    fi
}

# Basic health check
check_basic_health() {
    log "INFO" "Checking basic health endpoint: $HEALTH_URL"

    local attempt=1
    while [ $attempt -le $RETRY_COUNT ]; do
        if http_request "$HEALTH_URL" "GET" "$TIMEOUT" "200"; then
            log "INFO" "Basic health check passed (attempt $attempt)"
            return 0
        fi

        if [ $attempt -lt $RETRY_COUNT ]; then
            log "WARN" "Health check failed (attempt $attempt/$RETRY_COUNT), retrying in ${RETRY_DELAY}s..."
            sleep $RETRY_DELAY
        fi

        attempt=$((attempt + 1))
    done

    log "ERROR" "Basic health check failed after $RETRY_COUNT attempts"
    return 1
}

# Detailed health check
check_detailed_health() {
    log "INFO" "Checking detailed health endpoint: $DETAILED_HEALTH_URL"

    if ! http_request "$DETAILED_HEALTH_URL" "GET" "$TIMEOUT" "200"; then
        log "ERROR" "Detailed health check failed"
        return 1
    fi

    # Parse detailed health response
    local health_response
    health_response=$(curl -s --max-time "$TIMEOUT" "$DETAILED_HEALTH_URL" 2>/dev/null || echo "")

    if [ -n "$health_response" ]; then
        log "INFO" "Detailed health response: $health_response"

        # Check individual components
        echo "$health_response" | grep -q '"status":"ok"' || {
            log "ERROR" "Health status is not 'ok'"
            return 1
        }

        # Check database connectivity
        if echo "$health_response" | grep -q '"database"'; then
            local db_status
            db_status=$(echo "$health_response" | grep -o '"database":"[^"]*"' | cut -d'"' -f4)
            if [ "$db_status" != "ok" ]; then
                log "ERROR" "Database health check failed: $db_status"
                return 1
            fi
            log "INFO" "Database health: $db_status"
        fi

        # Check cache connectivity
        if echo "$health_response" | grep -q '"cache"'; then
            local cache_status
            cache_status=$(echo "$health_response" | grep -o '"cache":"[^"]*"' | cut -d'"' -f4)
            if [ "$cache_status" != "ok" ]; then
                log "WARN" "Cache health check failed: $cache_status"
                # Cache failure might not be critical
            else
                log "INFO" "Cache health: $cache_status"
            fi
        fi

        log "INFO" "Detailed health check passed"
    else
        log "WARN" "Could not parse detailed health response"
    fi

    return 0
}

# Metrics endpoint check
check_metrics_endpoint() {
    log "INFO" "Checking metrics endpoint: $METRICS_URL"

    if ! http_request "$METRICS_URL" "GET" "$TIMEOUT" "200"; then
        log "WARN" "Metrics endpoint check failed"
        return 1
    fi

    # Check if metrics contain expected pREST metrics
    local metrics_response
    metrics_response=$(curl -s --max-time "$TIMEOUT" "$METRICS_URL" 2>/dev/null || echo "")

    if echo "$metrics_response" | grep -q "prest_"; then
        log "INFO" "Metrics endpoint contains pREST metrics"
    else
        log "WARN" "Metrics endpoint does not contain expected pREST metrics"
    fi

    return 0
}

# Process health check
check_process_health() {
    log "INFO" "Checking pREST process health"

    # Check if pREST process is running
    local prest_pid
    if [ -f /var/run/prest.pid ]; then
        prest_pid=$(cat /var/run/prest.pid 2>/dev/null || echo "")
        if [ -n "$prest_pid" ] && kill -0 "$prest_pid" 2>/dev/null; then
            log "INFO" "pREST process is running (PID: $prest_pid)"
        else
            log "ERROR" "pREST process is not running (PID from file: $prest_pid)"
            return 1
        fi
    else
        log "WARN" "PID file not found, checking by process name"
        if pgrep -f "prestd" >/dev/null 2>&1; then
            log "INFO" "pREST process is running (found by name)"
        else
            log "ERROR" "pREST process is not running"
            return 1
        fi
    fi

    # Check process resource usage
    if command -v ps >/dev/null 2>&1; then
        local cpu_usage
        local memory_usage
        cpu_usage=$(ps -o %cpu= -p "$prest_pid" 2>/dev/null | tr -d ' ' || echo "0")
        memory_usage=$(ps -o %mem= -p "$prest_pid" 2>/dev/null | tr -d ' ' || echo "0")

        log "INFO" "CPU usage: ${cpu_usage}%, Memory usage: ${memory_usage}%"

        # Warn if resource usage is high
        if (( $(echo "$cpu_usage > 80" | bc -l 2>/dev/null || echo 0) )); then
            log "WARN" "High CPU usage: ${cpu_usage}%"
        fi

        if (( $(echo "$memory_usage > 80" | bc -l 2>/dev/null || echo 0) )); then
            log "WARN" "High memory usage: ${memory_usage}%"
        fi
    fi

    return 0
}

# Network connectivity check
check_network_connectivity() {
    log "INFO" "Checking network connectivity"

    # Check if pREST is listening on the expected port
    if netstat -ln 2>/dev/null | grep ":$PREST_PORT " >/dev/null 2>&1; then
        log "INFO" "pREST is listening on port $PREST_PORT"
    elif ss -ln 2>/dev/null | grep ":$PREST_PORT " >/dev/null 2>&1; then
        log "INFO" "pREST is listening on port $PREST_PORT"
    else
        log "ERROR" "pREST is not listening on port $PREST_PORT"
        return 1
    fi

    # Check local connectivity
    if nc -z localhost "$PREST_PORT" 2>/dev/null; then
        log "INFO" "Local connectivity to port $PREST_PORT is working"
    else
        log "ERROR" "Local connectivity to port $PREST_PORT failed"
        return 1
    fi

    return 0
}

# Database connectivity check
check_database_connectivity() {
    log "INFO" "Checking database connectivity"

    # Environment variables
    local pg_host="${PREST_PG_HOST:-localhost}"
    local pg_port="${PREST_PG_PORT:-5432}"
    local pg_user="${PREST_PG_USER:-postgres}"
    local pg_database="${PREST_PG_DATABASE:-agentstack}"
    local pg_ssl_mode="${PREST_SSL_MODE:-prefer}"

    # Check if PostgreSQL is reachable
    if command -v pg_isready >/dev/null 2>&1; then
        if pg_isready -h "$pg_host" -p "$pg_port" -U "$pg_user" -d "$pg_database" >/dev/null 2>&1; then
            log "INFO" "PostgreSQL server is ready"
        else
            log "ERROR" "PostgreSQL server is not ready"
            return 1
        fi
    else
        log "WARN" "pg_isready not available, skipping PostgreSQL readiness check"
    fi

    # Test database connection using psql if available
    if command -v psql >/dev/null 2>&1; then
        local connection_string="postgresql://$pg_user:$PREST_PG_PASS@$pg_host:$pg_port/$pg_database?sslmode=$pg_ssl_mode"
        if timeout 10 psql "$connection_string" -c "SELECT 1;" >/dev/null 2>&1; then
            log "INFO" "Database connection test passed"
        else
            log "ERROR" "Database connection test failed"
            return 1
        fi
    else
        log "WARN" "psql not available, skipping database connection test"
    fi

    return 0
}

# Cache connectivity check
check_cache_connectivity() {
    local cache_enabled="${PREST_CACHE_ENABLED:-true}"

    if [ "$cache_enabled" != "true" ]; then
        log "INFO" "Cache is disabled, skipping cache connectivity check"
        return 0
    fi

    log "INFO" "Checking cache connectivity"

    local redis_host="${REDIS_HOST:-localhost}"
    local redis_port="${REDIS_PORT:-6379}"

    if command -v redis-cli >/dev/null 2>&1; then
        local redis_cmd="redis-cli -h $redis_host -p $redis_port"

        if [ -n "${REDIS_PASSWORD:-}" ]; then
            redis_cmd="$redis_cmd -a $REDIS_PASSWORD"
        fi

        if timeout 10 $redis_cmd ping >/dev/null 2>&1; then
            log "INFO" "Redis connectivity test passed"

            # Test Redis operations
            local test_key="health_check_$(date +%s)"
            if $redis_cmd set "$test_key" "ok" >/dev/null 2>&1 && \
               $redis_cmd get "$test_key" >/dev/null 2>&1 && \
               $redis_cmd del "$test_key" >/dev/null 2>&1; then
                log "INFO" "Redis operations test passed"
            else
                log "WARN" "Redis operations test failed"
            fi
        else
            log "WARN" "Redis connectivity test failed"
            return 1
        fi
    else
        log "WARN" "redis-cli not available, skipping cache connectivity check"
    fi

    return 0
}

# SSL certificate check
check_ssl_certificates() {
    if [ "$PREST_SCHEME" = "http" ]; then
        log "INFO" "SSL is not enabled, skipping certificate check"
        return 0
    fi

    log "INFO" "Checking SSL certificates"

    local cert_file="${PREST_SSL_CERT:-/opt/prest/ssl/server.crt}"
    local key_file="${PREST_SSL_KEY:-/opt/prest/ssl/server.key}"

    # Check certificate file
    if [ -f "$cert_file" ]; then
        local cert_expiry
        cert_expiry=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2 || echo "")
        if [ -n "$cert_expiry" ]; then
            local expiry_timestamp
            expiry_timestamp=$(date -d "$cert_expiry" +%s 2>/dev/null || echo "0")
            local current_timestamp
            current_timestamp=$(date +%s)
            local days_until_expiry
            days_until_expiry=$(( (expiry_timestamp - current_timestamp) / 86400 ))

            if [ $days_until_expiry -lt 30 ]; then
                log "WARN" "SSL certificate expires in $days_until_expiry days"
            else
                log "INFO" "SSL certificate is valid for $days_until_expiry more days"
            fi

            if [ $days_until_expiry -lt 0 ]; then
                log "ERROR" "SSL certificate has expired"
                return 1
            fi
        else
            log "WARN" "Could not parse SSL certificate expiry date"
        fi
    else
        log "WARN" "SSL certificate file not found: $cert_file"
    fi

    # Check key file
    if [ -f "$key_file" ]; then
        log "INFO" "SSL key file found: $key_file"
    else
        log "WARN" "SSL key file not found: $key_file"
    fi

    return 0
}

# Performance check
check_performance() {
    log "INFO" "Checking performance metrics"

    # Response time check
    local start_time end_time response_time
    start_time=$(date +%s%N 2>/dev/null || date +%s)

    if http_request "$HEALTH_URL" "GET" "5" "200"; then
        end_time=$(date +%s%N 2>/dev/null || date +%s)
        response_time=$(( (end_time - start_time) / 1000000 ))  # Convert to milliseconds

        if [ $response_time -lt 100 ]; then
            log "INFO" "Response time: ${response_time}ms (good)"
        elif [ $response_time -lt 500 ]; then
            log "WARN" "Response time: ${response_time}ms (slow)"
        else
            log "ERROR" "Response time: ${response_time}ms (too slow)"
            return 1
        fi
    else
        log "ERROR" "Performance check failed"
        return 1
    fi

    return 0
}

# Comprehensive health check
run_comprehensive_health_check() {
    log "INFO" "Running comprehensive health check"

    local failed_checks=0

    # Run all health checks
    check_process_health || ((failed_checks++))
    check_network_connectivity || ((failed_checks++))
    check_basic_health || ((failed_checks++))
    check_detailed_health || ((failed_checks++))
    check_database_connectivity || ((failed_checks++))
    check_cache_connectivity || ((failed_checks++))
    check_ssl_certificates || ((failed_checks++))
    check_performance || ((failed_checks++))

    # Optional metrics check
    check_metrics_endpoint || log "WARN" "Metrics check failed (non-critical)"

    # Overall health status
    if [ $failed_checks -eq 0 ]; then
        log "INFO" "All health checks passed"
        return 0
    else
        log "ERROR" "$failed_checks health check(s) failed"
        return 1
    fi
}

# Quick health check (for container health checks)
run_quick_health_check() {
    if [ "${HEALTH_CHECK_MODE:-basic}" = "comprehensive" ]; then
        run_comprehensive_health_check
    else
        check_basic_health
    fi
}

# Main function
main() {
    local mode="${1:-basic}"

    case "$mode" in
        "basic")
            run_quick_health_check
            ;;
        "comprehensive")
            run_comprehensive_health_check
            ;;
        "process")
            check_process_health
            ;;
        "network")
            check_network_connectivity
            ;;
        "database")
            check_database_connectivity
            ;;
        "cache")
            check_cache_connectivity
            ;;
        "ssl")
            check_ssl_certificates
            ;;
        "performance")
            check_performance
            ;;
        *)
            log "ERROR" "Unknown health check mode: $mode"
            echo "Usage: $0 [basic|comprehensive|process|network|database|cache|ssl|performance]"
            exit 1
            ;;
    esac
}

# Execute main function with all arguments
main "$@"