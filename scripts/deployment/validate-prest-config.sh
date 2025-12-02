#!/bin/bash
# =============================================================================
# AgentStack OSS - pREST Configuration Validation Script
# Version: 2.0.0
# Description: Comprehensive validation of pREST configuration files
# =============================================================================
# Usage: ./validate-prest-config.sh [options]
# Options:
#   -c, --config FILE          Configuration file to validate
#   -e, --env ENVIRONMENT     Environment (production|staging|development)
#   -s, --strict              Enable strict validation mode
#   -f, --fix                 Attempt to fix common configuration issues
#   -o, --output FORMAT       Output format (json|yaml|table)
#   -h, --help                Show this help message
# =============================================================================

set -euo pipefail

# Default configuration
DEFAULT_CONFIG_FILE="config/prest/prest.toml"
DEFAULT_ENVIRONMENT="production"
DEFAULT_OUTPUT_FORMAT="table"
STRICT_MODE=false
FIX_ISSUES=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Validation results
VALIDATION_ERRORS=0
VALIDATION_WARNINGS=0
VALIDATION_INFO=0

# Global variables
CONFIG_FILE=""
ENVIRONMENT="$DEFAULT_ENVIRONMENT"
OUTPUT_FORMAT="$DEFAULT_OUTPUT_FORMAT"
VALIDATION_RESULTS=()

# Logging functions
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date -u '+%Y-%m-%d %H:%M:%S')

    case "$level" in
        "ERROR")
            echo -e "${RED}[ERROR]${NC} $message"
            ((VALIDATION_ERRORS++))
            ;;
        "WARN")
            echo -e "${YELLOW}[WARN]${NC}  $message"
            ((VALIDATION_WARNINGS++))
            ;;
        "INFO")
            echo -e "${BLUE}[INFO]${NC}  $message"
            ((VALIDATION_INFO++))
            ;;
        "SUCCESS")
            echo -e "${GREEN}[SUCCESS]${NC} $message"
            ;;
        "DEBUG")
            echo -e "${PURPLE}[DEBUG]${NC} $message"
            ;;
    esac
}

# Show help
show_help() {
    cat << EOF
AgentStack OSS - pREST Configuration Validation Script

USAGE:
    $0 [OPTIONS]

OPTIONS:
    -c, --config FILE          Configuration file to validate
                                Default: $DEFAULT_CONFIG_FILE
    -e, --env ENVIRONMENT     Environment (production|staging|development)
                                Default: $DEFAULT_ENVIRONMENT
    -s, --strict              Enable strict validation mode
    -f, --fix                 Attempt to fix common configuration issues
    -o, --output FORMAT       Output format (json|yaml|table)
                                Default: $DEFAULT_OUTPUT_FORMAT
    -h, --help                Show this help message

EXAMPLES:
    $0 --config config/prest/prest.toml --env production
    $0 --strict --fix --output json
    $0 --env staging --config /path/to/prest.toml

EOF
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -e|--env)
                ENVIRONMENT="$2"
                shift 2
                ;;
            -s|--strict)
                STRICT_MODE=true
                shift
                ;;
            -f|--fix)
                FIX_ISSUES=true
                shift
                ;;
            -o|--output)
                OUTPUT_FORMAT="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                echo "Unknown argument: $1"
                show_help
                exit 1
                ;;
        esac
    done

    # Set default config file if not provided
    if [ -z "$CONFIG_FILE" ]; then
        CONFIG_FILE="$DEFAULT_CONFIG_FILE"
    fi
}

# Validate basic configuration
validate_basic_config() {
    log "INFO" "Validating basic configuration"

    if [ ! -f "$CONFIG_FILE" ]; then
        log "ERROR" "Configuration file not found: $CONFIG_FILE"
        return 1
    fi

    # Check file permissions
    local file_perms
    file_perms=$(stat -c "%a" "$CONFIG_FILE" 2>/dev/null || stat -f "%A" "$CONFIG_FILE" 2>/dev/null || echo "unknown")
    if [ "$file_perms" != "600" ] && [ "$ENVIRONMENT" = "production" ]; then
        log "WARN" "Configuration file has insecure permissions: $file_perms (recommended: 600)"
        if [ "$FIX_ISSUES" = true ]; then
            chmod 600 "$CONFIG_FILE" && log "INFO" "Fixed file permissions to 600"
        fi
    fi

    # Check if file is readable
    if [ ! -r "$CONFIG_FILE" ]; then
        log "ERROR" "Configuration file is not readable: $CONFIG_FILE"
        return 1
    fi

    log "SUCCESS" "Basic configuration validation passed"
}

# Validate TOML syntax
validate_toml_syntax() {
    log "INFO" "Validating TOML syntax"

    if command -v toml >/dev/null 2>&1; then
        if toml "$CONFIG_FILE" >/dev/null 2>&1; then
            log "SUCCESS" "TOML syntax is valid"
        else
            log "ERROR" "Invalid TOML syntax in configuration file"
            return 1
        fi
    else
        log "WARN" "toml parser not available, skipping syntax validation"
        log "INFO" "Install toml-cli: pip install toml-cli"
    fi
}

# Validate server configuration
validate_server_config() {
    log "INFO" "Validating server configuration"

    # Check for required server settings
    local required_server_settings=(
        "server.host"
        "server.port"
    )

    for setting in "${required_server_settings[@]}"; do
        if ! grep -q "^\[server\]" "$CONFIG_FILE" 2>/dev/null; then
            log "ERROR" "Missing [server] section"
            continue
        fi

        local key="${setting#server.}"
        if ! grep -q "^$key.*=" "$CONFIG_FILE" 2>/dev/null; then
            log "ERROR" "Missing server setting: $key"
        else
            log "SUCCESS" "Found server setting: $key"
        fi
    done

    # Validate port range
    local port
    port=$(grep "^port.*=" "$CONFIG_FILE" 2>/dev/null | head -1 | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" || echo "")
    if [ -n "$port" ]; then
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            log "ERROR" "Invalid port number: $port (must be 1-65535)"
        else
            log "SUCCESS" "Valid port number: $port"
        fi
    fi

    # Check SSL configuration for production
    if [ "$ENVIRONMENT" = "production" ]; then
        if ! grep -q "^\[server.tls\]" "$CONFIG_FILE" 2>/dev/null; then
            log "WARN" "Missing [server.tls] section in production environment"
        else
            log "SUCCESS" "Found TLS configuration section"
        fi
    fi
}

# Validate database configuration
validate_database_config() {
    log "INFO" "Validating database configuration"

    local required_db_settings=(
        "database.host"
        "database.port"
        "database.user"
        "database.pass"
        "database.database"
    )

    for setting in "${required_db_settings[@]}"; do
        if ! grep -q "^\[database\]" "$CONFIG_FILE" 2>/dev/null; then
            log "ERROR" "Missing [database] section"
            continue
        fi

        local key="${setting#database.}"
        if ! grep -q "^$key.*=" "$CONFIG_FILE" 2>/dev/null; then
            log "ERROR" "Missing database setting: $key"
        else
            log "SUCCESS" "Found database setting: $key"
        fi
    done

    # Validate database port
    local db_port
    db_port=$(grep -A10 "^\[database\]" "$CONFIG_FILE" | grep "^port.*=" | head -1 | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" || echo "")
    if [ -n "$db_port" ]; then
        if ! [[ "$db_port" =~ ^[0-9]+$ ]] || [ "$db_port" -lt 1 ] || [ "$db_port" -gt 65535 ]; then
            log "ERROR" "Invalid database port: $db_port (must be 1-65535)"
        else
            log "SUCCESS" "Valid database port: $db_port"
        fi
    fi

    # Check connection pool settings
    local max_open_conn
    max_open_conn=$(grep -A10 "^\[database\]" "$CONFIG_FILE" | grep "^max_open_conn.*=" | head -1 | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" || echo "")
    if [ -n "$max_open_conn" ]; then
        if ! [[ "$max_open_conn" =~ ^[0-9]+$ ]] || [ "$max_open_conn" -lt 1 ] || [ "$max_open_conn" -gt 1000 ]; then
            log "WARN" "Potentially invalid max_open_conn: $max_open_conn (recommended: 1-1000)"
        else
            log "SUCCESS" "Valid max_open_conn: $max_open_conn"
        fi
    fi
}

# Validate authentication configuration
validate_auth_config() {
    log "INFO" "Validating authentication configuration"

    # Check if auth section exists
    if ! grep -q "^\[auth\]" "$CONFIG_FILE" 2>/dev/null; then
        log "ERROR" "Missing [auth] section"
        return 1
    fi

    # Check if authentication is enabled
    local auth_enabled
    auth_enabled=$(grep -A5 "^\[auth\]" "$CONFIG_FILE" | grep "^enabled.*=" | head -1 | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" || echo "")
    if [ "$auth_enabled" = "true" ]; then
        log "SUCCESS" "Authentication is enabled"

        # Check JWT configuration
        if grep -q "^\[auth.jwt\]" "$CONFIG_FILE" 2>/dev/null; then
            local jwt_secret
            jwt_secret=$(grep -A10 "^\[auth.jwt\]" "$CONFIG_FILE" | grep "^secret.*=" | head -1 | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" || echo "")

            if [ -z "$jwt_secret" ] || [ "$jwt_secret" = "\${PREST_JWT_KEY}" ] || [ "$jwt_secret" = "\${PREST_JWT_KEY:-change-me}" ]; then
                log "ERROR" "JWT secret is not properly configured"
            elif [ ${#jwt_secret} -lt 32 ]; then
                log "ERROR" "JWT secret is too short (minimum 32 characters recommended)"
            else
                log "SUCCESS" "JWT secret is properly configured"
            fi
        else
            log "ERROR" "Missing [auth.jwt] section"
        fi
    else
        log "WARN" "Authentication is disabled (not recommended for production)"
    fi

    # Check RBAC configuration
    if grep -q "^\[auth.rbac\]" "$CONFIG_FILE" 2>/dev/null; then
        log "SUCCESS" "Found RBAC configuration"
    else
        log "WARN" "Missing [auth.rbac] section"
    fi
}

# Validate security configuration
validate_security_config() {
    log "INFO" "Validating security configuration"

    # Check security section
    if ! grep -q "^\[security\]" "$CONFIG_FILE" 2>/dev/null; then
        log "ERROR" "Missing [security] section"
        return 1
    fi

    # Check security headers
    local headers_enabled
    headers_enabled=$(grep -A5 "^\[security\]" "$CONFIG_FILE" | grep "^headers_enabled.*=" | head -1 | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" || echo "")
    if [ "$headers_enabled" = "true" ]; then
        log "SUCCESS" "Security headers are enabled"
    else
        log "WARN" "Security headers are disabled"
    fi

    # Check rate limiting
    local rate_limiting_enabled
    rate_limiting_enabled=$(grep -A5 "^\[security\]" "$CONFIG_FILE" | grep "^rate_limiting_enabled.*=" | head -1 | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" || echo "")
    if [ "$rate_limiting_enabled" = "true" ]; then
        log "SUCCESS" "Rate limiting is enabled"
    else
        log "WARN" "Rate limiting is disabled (not recommended for production)"
    fi

    # Check CORS configuration
    if grep -q "^\[security.cors\]" "$CONFIG_FILE" 2>/dev/null; then
        log "SUCCESS" "Found CORS configuration"

        # Check if CORS is properly configured for production
        if [ "$ENVIRONMENT" = "production" ]; then
            local allow_origins
            allow_origins=$(grep -A10 "^\[security.cors\]" "$CONFIG_FILE" | grep "^allow_origins.*=" | head -1 | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" || echo "")
            if [[ "$allow_origins" == *"*"* ]]; then
                log "ERROR" "CORS allows all origins in production (security risk)"
            else
                log "SUCCESS" "CORS origins are properly restricted"
            fi
        fi
    else
        log "WARN" "Missing [security.cors] section"
    fi
}

# Validate monitoring configuration
validate_monitoring_config() {
    log "INFO" "Validating monitoring configuration"

    # Check monitoring section
    if ! grep -q "^\[monitoring\]" "$CONFIG_FILE" 2>/dev/null; then
        log "ERROR" "Missing [monitoring] section"
        return 1
    fi

    # Check if metrics are enabled
    local metrics_enabled
    metrics_enabled=$(grep -A5 "^\[monitoring\]" "$CONFIG_FILE" | grep "^metrics_enabled.*=" | head -1 | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" || echo "")
    if [ "$metrics_enabled" = "true" ]; then
        log "SUCCESS" "Metrics are enabled"

        # Check metrics configuration
        if grep -q "^\[monitoring.metrics\]" "$CONFIG_FILE" 2>/dev/null; then
            log "SUCCESS" "Found metrics configuration"
        else
            log "WARN" "Missing [monitoring.metrics] section"
        fi
    else
        log "WARN" "Metrics are disabled (not recommended for production)"
    fi

    # Check tracing configuration
    local tracing_enabled
    tracing_enabled=$(grep -A5 "^\[monitoring\]" "$CONFIG_FILE" | grep "^tracing_enabled.*=" | head -1 | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" || echo "")
    if [ "$tracing_enabled" = "true" ]; then
        log "SUCCESS" "Tracing is enabled"

        if grep -q "^\[monitoring.tracing\]" "$CONFIG_FILE" 2>/dev/null; then
            log "SUCCESS" "Found tracing configuration"
        else
            log "WARN" "Missing [monitoring.tracing] section"
        fi
    else
        log "INFO" "Tracing is disabled"
    fi

    # Check logging configuration
    if grep -q "^\[monitoring.logging\]" "$CONFIG_FILE" 2>/dev/null; then
        log "SUCCESS" "Found logging configuration"
    else
        log "WARN" "Missing [monitoring.logging] section"
    fi
}

# Validate performance configuration
validate_performance_config() {
    log "INFO" "Validating performance configuration"

    if ! grep -q "^\[performance\]" "$CONFIG_FILE" 2>/dev/null; then
        log "WARN" "Missing [performance] section"
        return 1
    fi

    # Check query limits
    local default_limit
    default_limit=$(grep -A10 "^\[performance\]" "$CONFIG_FILE" | grep "^default_limit.*=" | head -1 | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" || echo "")
    if [ -n "$default_limit" ]; then
        if ! [[ "$default_limit" =~ ^[0-9]+$ ]] || [ "$default_limit" -lt 1 ] || [ "$default_limit" -gt 10000 ]; then
            log "WARN" "Potentially invalid default_limit: $default_limit (recommended: 1-10000)"
        else
            log "SUCCESS" "Valid default_limit: $default_limit"
        fi
    fi

    # Check compression settings
    local compression_enabled
    compression_enabled=$(grep -A10 "^\[performance\]" "$CONFIG_FILE" | grep "^compression_enabled.*=" | head -1 | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" || echo "")
    if [ "$compression_enabled" = "true" ]; then
        log "SUCCESS" "Compression is enabled"
    else
        log "WARN" "Compression is disabled (may affect performance)"
    fi

    # Check timeout settings
    local query_timeout
    query_timeout=$(grep -A10 "^\[performance\]" "$CONFIG_FILE" | grep "^timeout.*=" | head -1 | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" || echo "")
    if [ -n "$query_timeout" ]; then
        if ! [[ "$query_timeout" =~ ^[0-9]+$ ]] || [ "$query_timeout" -lt 5 ] || [ "$query_timeout" -gt 300 ]; then
            log "WARN" "Potentially invalid timeout: $query_timeout (recommended: 5-300 seconds)"
        else
            log "SUCCESS" "Valid timeout: $query_timeout seconds"
        fi
    fi
}

# Validate environment-specific settings
validate_environment_config() {
    log "INFO" "Validating environment-specific configuration"

    if ! grep -q "^\[environments\.$ENVIRONMENT\]" "$CONFIG_FILE" 2>/dev/null; then
        log "WARN" "Missing [environments.$ENVIRONMENT] section"
    else
        log "SUCCESS" "Found environment-specific configuration for $ENVIRONMENT"
    fi

    # Environment-specific validations
    case "$ENVIRONMENT" in
        "production")
            if grep -q "debug.*=.*true" "$CONFIG_FILE" 2>/dev/null; then
                log "WARN" "Debug mode is enabled in production (not recommended)"
            fi

            if grep -q "log_level.*=.*debug" "$CONFIG_FILE" 2>/dev/null; then
                log "WARN" "Debug logging is enabled in production"
            fi

            if grep -q "cache_enabled.*=.*false" "$CONFIG_FILE" 2>/dev/null; then
                log "WARN" "Cache is disabled in production (may affect performance)"
            fi
            ;;
        "development")
            log "INFO" "Development environment validation passed"
            ;;
        "staging")
            log "INFO" "Staging environment validation passed"
            ;;
    esac
}

# Validate SSL/TLS configuration
validate_ssl_config() {
    log "INFO" "Validating SSL/TLS configuration"

    if ! grep -q "^\[server.tls\]" "$CONFIG_FILE" 2>/dev/null; then
        if [ "$ENVIRONMENT" = "production" ]; then
            log "ERROR" "SSL/TLS is not configured for production environment"
        else
            log "WARN" "SSL/TLS is not configured"
        fi
        return 1
    fi

    local tls_enabled
    tls_enabled=$(grep -A5 "^\[server.tls\]" "$CONFIG_FILE" | grep "^enabled.*=" | head -1 | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" || echo "")
    if [ "$tls_enabled" = "true" ]; then
        log "SUCCESS" "SSL/TLS is enabled"

        # Check certificate files
        local cert_file
        cert_file=$(grep -A10 "^\[server.tls\]" "$CONFIG_FILE" | grep "^cert_file.*=" | head -1 | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" || echo "")
        local key_file
        key_file=$(grep -A10 "^\[server.tls\]" "$CONFIG_FILE" | grep "^key_file.*=" | head -1 | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" || echo "")

        if [ -n "$cert_file" ]; then
            if [ ! -f "$cert_file" ]; then
                log "ERROR" "SSL certificate file not found: $cert_file"
            else
                log "SUCCESS" "SSL certificate file found: $cert_file"
            fi
        fi

        if [ -n "$key_file" ]; then
            if [ ! -f "$key_file" ]; then
                log "ERROR" "SSL key file not found: $key_file"
            else
                log "SUCCESS" "SSL key file found: $key_file"
            fi
        fi

        # Check TLS version
        local min_version
        min_version=$(grep -A10 "^\[server.tls\]" "$CONFIG_FILE" | grep "^min_version.*=" | head -1 | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" || echo "")
        if [ -n "$min_version" ]; then
            if [[ "$min_version" == "1.0" ]] || [[ "$min_version" == "1.1" ]]; then
                log "WARN" "TLS minimum version is too low: $min_version (recommended: 1.2 or higher)"
            else
                log "SUCCESS" "TLS minimum version is acceptable: $min_version"
            fi
        fi
    else
        log "WARN" "SSL/TLS is disabled"
    fi
}

# Validate cache configuration
validate_cache_config() {
    log "INFO" "Validating cache configuration"

    if ! grep -q "^\[cache\]" "$CONFIG_FILE" 2>/dev/null; then
        log "WARN" "Missing [cache] section"
        return 1
    fi

    local cache_enabled
    cache_enabled=$(grep -A5 "^\[cache\]" "$CONFIG_FILE" | grep "^enabled.*=" | head -1 | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" || echo "")
    if [ "$cache_enabled" = "true" ]; then
        log "SUCCESS" "Cache is enabled"

        # Check cache type
        local cache_type
        cache_type=$(grep -A10 "^\[cache\]" "$CONFIG_FILE" | grep "^type.*=" | head -1 | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" || echo "")
        case "$cache_type" in
            "redis"|"memory")
                log "SUCCESS" "Valid cache type: $cache_type"
                ;;
            *)
                log "WARN" "Unknown cache type: $cache_type"
                ;;
        esac

        # Check Redis configuration if using Redis
        if [ "$cache_type" = "redis" ]; then
            if grep -q "^\[cache.redis\]" "$CONFIG_FILE" 2>/dev/null; then
                log "SUCCESS" "Found Redis cache configuration"
            else
                log "ERROR" "Missing [cache.redis] section for Redis cache"
            fi
        fi
    else
        log "INFO" "Cache is disabled"
    fi
}

# Validate plugin configuration
validate_plugin_config() {
    log "INFO" "Validating plugin configuration"

    if ! grep -q "^\[plugins\]" "$CONFIG_FILE" 2>/dev/null; then
        log "WARN" "Missing [plugins] section"
        return 1
    fi

    local plugins_enabled
    plugins_enabled=$(grep -A5 "^\[plugins\]" "$CONFIG_FILE" | grep "^enabled.*=" | head -1 | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" || echo "")
    if [ "$plugins_enabled" = "true" ]; then
        log "SUCCESS" "Plugins are enabled"

        # Check plugin path
        local plugin_path
        plugin_path=$(grep -A10 "^\[plugins\]" "$CONFIG_FILE" | grep "^plugin_path.*=" | head -1 | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" || echo "")
        if [ -n "$plugin_path" ]; then
            if [ ! -d "$plugin_path" ]; then
                log "WARN" "Plugin directory not found: $plugin_path"
            else
                log "SUCCESS" "Plugin directory found: $plugin_path"
            fi
        fi
    else
        log "INFO" "Plugins are disabled"
    fi
}

# Check for common security issues
check_security_issues() {
    log "INFO" "Checking for common security issues"

    # Check for hardcoded secrets
    local sensitive_patterns=("password.*=" "secret.*=" "key.*=" "token.*=")
    for pattern in "${sensitive_patterns[@]}"; do
        if grep -i "$pattern" "$CONFIG_FILE" | grep -v "\${" | grep -v "localhost\|127.0.0.1\|example" >/dev/null 2>&1; then
            log "ERROR" "Potential hardcoded secret found matching pattern: $pattern"
        fi
    done

    # Check for weak TLS settings
    if grep -i "min_version.*=.*\"1.0\"" "$CONFIG_FILE" >/dev/null 2>&1; then
        log "ERROR" "TLS 1.0 is enabled (security vulnerability)"
    fi

    # Check for wildcard origins in production
    if [ "$ENVIRONMENT" = "production" ] && grep -i "allow_origins.*=.*\"\*\"" "$CONFIG_FILE" >/dev/null 2>&1; then
        log "ERROR" "Wildcard CORS origins in production (security vulnerability)"
    fi

    # Check for disabled security features in production
    if [ "$ENVIRONMENT" = "production" ]; then
        if grep -i "headers_enabled.*=.*false" "$CONFIG_FILE" >/dev/null 2>&1; then
            log "ERROR" "Security headers disabled in production"
        fi

        if grep -i "rate_limiting_enabled.*=.*false" "$CONFIG_FILE" >/dev/null 2>&1; then
            log "ERROR" "Rate limiting disabled in production"
        fi
    fi
}

# Generate validation report
generate_report() {
    log "INFO" "Generating validation report"

    local total_issues=$((VALIDATION_ERRORS + VALIDATION_WARNINGS))

    case "$OUTPUT_FORMAT" in
        "json")
            generate_json_report
            ;;
        "yaml")
            generate_yaml_report
            ;;
        "table"|*)
            generate_table_report
            ;;
    esac

    # Return appropriate exit code
    if [ "$VALIDATION_ERRORS" -gt 0 ]; then
        return 1
    elif [ "$STRICT_MODE" = true ] && [ "$VALIDATION_WARNINGS" -gt 0 ]; then
        return 1
    else
        return 0
    fi
}

generate_table_report() {
    echo
    echo "==================================="
    echo "CONFIGURATION VALIDATION REPORT"
    echo "==================================="
    echo "Configuration File: $CONFIG_FILE"
    echo "Environment: $ENVIRONMENT"
    echo "Strict Mode: $STRICT_MODE"
    echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    echo "RESULTS SUMMARY:"
    echo "  Errors:   $VALIDATION_ERRORS"
    echo "  Warnings: $VALIDATION_WARNINGS"
    echo "  Info:     $VALIDATION_INFO"
    echo "  Total Issues: $total_issues"
    echo

    if [ "$VALIDATION_ERRORS" -gt 0 ]; then
        echo "STATUS: FAILED"
    elif [ "$STRICT_MODE" = true ] && [ "$VALIDATION_WARNINGS" -gt 0 ]; then
        echo "STATUS: FAILED (strict mode)"
    else
        echo "STATUS: PASSED"
    fi
    echo
}

generate_json_report() {
    cat << EOF
{
    "validation_report": {
        "config_file": "$CONFIG_FILE",
        "environment": "$ENVIRONMENT",
        "strict_mode": $STRICT_MODE,
        "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
        "results": {
            "errors": $VALIDATION_ERRORS,
            "warnings": $VALIDATION_WARNINGS,
            "info": $VALIDATION_INFO,
            "total_issues": $((VALIDATION_ERRORS + VALIDATION_WARNINGS))
        },
        "status": "$([ "$VALIDATION_ERRORS" -gt 0 ] && echo "FAILED" || ([ "$STRICT_MODE" = true ] && [ "$VALIDATION_WARNINGS" -gt 0 ] && echo "FAILED" || echo "PASSED"))"
    }
}
EOF
}

generate_yaml_report() {
    cat << EOF
validation_report:
  config_file: "$CONFIG_FILE"
  environment: "$ENVIRONMENT"
  strict_mode: $STRICT_MODE
  timestamp: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  results:
    errors: $VALIDATION_ERRORS
    warnings: $VALIDATION_WARNINGS
    info: $VALIDATION_INFO
    total_issues: $((VALIDATION_ERRORS + VALIDATION_WARNINGS))
  status: "$([ "$VALIDATION_ERRORS" -gt 0 ] && echo "FAILED" || ([ "$STRICT_MODE" = true ] && [ "$VALIDATION_WARNINGS" -gt 0 ] && echo "FAILED" || echo "PASSED"))"
EOF
}

# Main validation function
main() {
    echo "AgentStack pREST Configuration Validation"
    echo "========================================"

    parse_arguments "$@"

    # Run all validation checks
    validate_basic_config
    validate_toml_syntax
    validate_server_config
    validate_database_config
    validate_auth_config
    validate_security_config
    validate_monitoring_config
    validate_performance_config
    validate_environment_config
    validate_ssl_config
    validate_cache_config
    validate_plugin_config
    check_security_issues

    # Generate final report
    generate_report
}

# Execute main function with all arguments
main "$@"