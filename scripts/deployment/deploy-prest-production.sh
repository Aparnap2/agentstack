#!/bin/bash
# =============================================================================
# AgentStack OSS - Production pREST Deployment Script
# Version: 2.0.0
# Description: Automated production deployment with validation and rollback
# =============================================================================
# Usage: ./deploy-prest-production.sh [options]
# Options:
#   -e, --env ENVIRONMENT        Environment (production|staging|development)
#   -v, --version VERSION       Version to deploy (default: latest)
#   -b, --backup                Create database backup before deployment
#   -r, --rollback              Rollback to previous version
#   -d, --dry-run               Simulate deployment without making changes
#   -f, --force                 Force deployment (skip confirmations)
#   -c, --config FILE           Custom configuration file
#   -l, --log-level LEVEL       Log level (debug|info|warn|error)
#   -h, --help                  Show this help message
# =============================================================================

set -euo pipefail

# Default configuration
DEFAULT_ENVIRONMENT="production"
DEFAULT_VERSION="latest"
DEFAULT_LOG_LEVEL="info"
DEFAULT_CONFIG_FILE=".env.production"

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$PROJECT_ROOT/docker-compose.prest-production.yml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Global variables
ENVIRONMENT="$DEFAULT_ENVIRONMENT"
VERSION="$DEFAULT_VERSION"
LOG_LEVEL="$DEFAULT_LOG_LEVEL"
CONFIG_FILE="$DEFAULT_CONFIG_FILE"
BACKUP_ENABLED=false
ROLLBACK_ENABLED=false
DRY_RUN=false
FORCE_DEPLOY=false
DEPLOYMENT_ID=""
BACKUP_FILE=""
PREVIOUS_VERSION=""

# Logging functions
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date -u '+%Y-%m-%d %H:%M:%S')

    case "$level" in
        "ERROR") echo -e "${RED}[ERROR]${NC} [$timestamp] $message" | tee -a "$PROJECT_ROOT/logs/deployment.log" >&2 ;;
        "WARN")  echo -e "${YELLOW}[WARN]${NC}  [$timestamp] $message" | tee -a "$PROJECT_ROOT/logs/deployment.log" ;;
        "INFO")  echo -e "${GREEN}[INFO]${NC}  [$timestamp] $message" | tee -a "$PROJECT_ROOT/logs/deployment.log" ;;
        "DEBUG") echo -e "${BLUE}[DEBUG]${NC} [$timestamp] $message" | tee -a "$PROJECT_ROOT/logs/deployment.log" ;;
        "SUCCESS") echo -e "${PURPLE}[SUCCESS]${NC} [$timestamp] $message" | tee -a "$PROJECT_ROOT/logs/deployment.log" ;;
        "STEP")   echo -e "${CYAN}[STEP]${NC}   [$timestamp] $message" | tee -a "$PROJECT_ROOT/logs/deployment.log" ;;
    esac

    # Only show logs at or above the specified log level
    case "$LOG_LEVEL" in
        "error") [[ "$level" == "ERROR" ]] || return 0 ;;
        "warn")  [[ "$level" =~ ^(ERROR|WARN)$ ]] || return 0 ;;
        "info")  [[ "$level" =~ ^(ERROR|WARN|INFO)$ ]] || return 0 ;;
        "debug") return 0 ;;
    esac
}

# Error handling
error_exit() {
    log "ERROR" "$1"
    cleanup_on_error
    exit 1
}

# Cleanup on error
cleanup_on_error() {
    if [ -n "$DEPLOYMENT_ID" ]; then
        log "INFO" "Cleaning up failed deployment: $DEPLOYMENT_ID"
        # Add cleanup logic here
    fi
}

# Show help
show_help() {
    cat << EOF
AgentStack OSS - Production pREST Deployment Script

USAGE:
    $0 [OPTIONS]

OPTIONS:
    -e, --env ENVIRONMENT        Environment (production|staging|development)
                                Default: $DEFAULT_ENVIRONMENT
    -v, --version VERSION       Version to deploy (default: $DEFAULT_VERSION)
    -b, --backup                Create database backup before deployment
    -r, --rollback              Rollback to previous version
    -d, --dry-run               Simulate deployment without making changes
    -f, --force                 Force deployment (skip confirmations)
    -c, --config FILE           Custom configuration file
                                Default: $DEFAULT_CONFIG_FILE
    -l, --log-level LEVEL       Log level (debug|info|warn|error)
                                Default: $DEFAULT_LOG_LEVEL
    -h, --help                  Show this help message

EXAMPLES:
    $0 --env production --backup
    $0 --env staging --version v2.0.1 --dry-run
    $0 --rollback --env production

EOF
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -e|--env)
                ENVIRONMENT="$2"
                shift 2
                ;;
            -v|--version)
                VERSION="$2"
                shift 2
                ;;
            -b|--backup)
                BACKUP_ENABLED=true
                shift
                ;;
            -r|--rollback)
                ROLLBACK_ENABLED=true
                shift
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -f|--force)
                FORCE_DEPLOY=true
                shift
                ;;
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -l|--log-level)
                LOG_LEVEL="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                error_exit "Unknown argument: $1"
                ;;
        esac
    done
}

# Validate arguments
validate_arguments() {
    log "STEP" "Validating deployment arguments"

    # Validate environment
    case "$ENVIRONMENT" in
        production|staging|development)
            log "INFO" "Environment: $ENVIRONMENT"
            ;;
        *)
            error_exit "Invalid environment: $ENVIRONMENT. Must be production, staging, or development"
            ;;
    esac

    # Validate log level
    case "$LOG_LEVEL" in
        debug|info|warn|error)
            log "INFO" "Log level: $LOG_LEVEL"
            ;;
        *)
            error_exit "Invalid log level: $LOG_LEVEL. Must be debug, info, warn, or error"
            ;;
    esac

    # Validate configuration file
    if [ ! -f "$PROJECT_ROOT/$CONFIG_FILE" ]; then
        error_exit "Configuration file not found: $PROJECT_ROOT/$CONFIG_FILE"
    fi
    log "INFO" "Configuration file: $CONFIG_FILE"

    # Validate compose file
    if [ ! -f "$COMPOSE_FILE" ]; then
        error_exit "Docker Compose file not found: $COMPOSE_FILE"
    fi
    log "INFO" "Compose file: $COMPOSE_FILE"

    # Check if running as root
    if [ "$EUID" -eq 0 ]; then
        error_exit "This script should not be run as root for security reasons"
    fi

    log "SUCCESS" "Argument validation completed"
}

# Load environment variables
load_environment() {
    log "STEP" "Loading environment variables"

    # Load configuration file
    set -a
    source "$PROJECT_ROOT/$CONFIG_FILE"
    set +a

    # Set environment-specific variables
    export ENVIRONMENT="$ENVIRONMENT"
    export DEPLOYMENT_ID="deploy-$(date +%Y%m%d-%H%M%S)-$(openssl rand -hex 4)"
    export COMPOSE_PROJECT_NAME="agentstack-prest-$ENVIRONMENT"

    # Version handling
    if [ "$VERSION" = "latest" ]; then
        VERSION=$(docker image inspect agentstack/prest:latest --format='{{.Id}}' 2>/dev/null | cut -d: -f2 | cut -c1-12 || echo "latest")
    fi
    export IMAGE_VERSION="$VERSION"

    log "INFO" "Deployment ID: $DEPLOYMENT_ID"
    log "INFO" "Image version: $IMAGE_VERSION"
    log "SUCCESS" "Environment variables loaded"
}

# Check prerequisites
check_prerequisites() {
    log "STEP" "Checking prerequisites"

    # Check required commands
    local required_commands=("docker" "docker-compose" "curl" "jq" "openssl")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            error_exit "Required command not found: $cmd"
        fi
    done

    # Check Docker daemon
    if ! docker info >/dev/null 2>&1; then
        error_exit "Docker daemon is not running"
    fi

    # Check Docker Compose
    if ! docker-compose --version >/dev/null 2>&1; then
        error_exit "Docker Compose is not available"
    fi

    # Check available disk space
    local available_space
    available_space=$(df -BG "$PROJECT_ROOT" | awk 'NR==2 {print $4}' | sed 's/G//')
    if [ "$available_space" -lt 5 ]; then
        log "WARN" "Low disk space: ${available_space}GB available (minimum 5GB recommended)"
    fi

    # Check available memory
    local available_memory
    available_memory=$(free -g | awk '/^Mem:/{print $7}')
    if [ "$available_memory" -lt 2 ]; then
        log "WARN" "Low memory: ${available_memory}GB available (minimum 2GB recommended)"
    fi

    log "SUCCESS" "Prerequisites check completed"
}

# Create backup
create_backup() {
    if [ "$BACKUP_ENABLED" = false ]; then
        log "INFO" "Backup skipped (not enabled)"
        return 0
    fi

    log "STEP" "Creating database backup"

    local backup_dir="$PROJECT_ROOT/backups/$ENVIRONMENT"
    local timestamp=$(date +%Y%m%d-%H%M%S)
    BACKUP_FILE="$backup_dir/prest-backup-$timestamp.sql"

    mkdir -p "$backup_dir"

    # Check if database is running
    if ! docker-compose -f "$COMPOSE_FILE" ps postgres | grep -q "Up"; then
        error_exit "Database is not running. Cannot create backup."
    fi

    # Create backup
    log "INFO" "Creating database backup: $BACKUP_FILE"

    if [ "$DRY_RUN" = false ]; then
        docker-compose -f "$COMPOSE_FILE" exec -T postgres pg_dump \
            -U "${POSTGRES_USER:-postgres}" \
            -d "${POSTGRES_DB:-agentstack}" \
            --no-owner \
            --no-privileges \
            --clean \
            --if-exists \
            > "$BACKUP_FILE" || error_exit "Failed to create database backup"

        # Compress backup
        gzip "$BACKUP_FILE"
        BACKUP_FILE="${BACKUP_FILE}.gz"

        log "INFO" "Backup created and compressed: $BACKUP_FILE"

        # Verify backup
        if [ -f "$BACKUP_FILE" ] && [ -s "$BACKUP_FILE" ]; then
            log "SUCCESS" "Backup verification passed"
        else
            error_exit "Backup verification failed"
        fi
    else
        log "INFO" "DRY RUN: Would create backup: $BACKUP_FILE"
    fi
}

# Get current version
get_current_version() {
    log "STEP" "Getting current deployment version"

    if docker-compose -f "$COMPOSE_FILE" ps prest-api | grep -q "Up"; then
        PREVIOUS_VERSION=$(docker-compose -f "$COMPOSE_FILE" images prest-api | grep -v "REPOSITORY" | awk '{print $2}' || echo "unknown")
        log "INFO" "Current version: $PREVIOUS_VERSION"
    else
        PREVIOUS_VERSION="none"
        log "INFO" "No current deployment found"
    fi
}

# Pull images
pull_images() {
    log "STEP" "Pulling Docker images"

    local images=(
        "agentstack/prest:$VERSION"
        "pgvector/pgvector:pg17-0.8.0"
        "pgbouncer/pgbouncer:latest"
        "traefik:v3.1"
        "prom/prometheus:v2.53.0"
        "grafana/grafana:11.2.0"
        "jaegertracing/all-in-one:1.58"
        "redis:7.2-alpine"
        "prometheuscommunity/postgres-exporter:v0.15.0"
    )

    for image in "${images[@]}"; do
        log "INFO" "Pulling image: $image"
        if [ "$DRY_RUN" = false ]; then
            docker pull "$image" || error_exit "Failed to pull image: $image"
        else
            log "INFO" "DRY RUN: Would pull image: $image"
        fi
    done

    log "SUCCESS" "All images pulled successfully"
}

# Build custom images
build_images() {
    log "STEP" "Building custom images"

    if [ "$DRY_RUN" = false ]; then
        # Build pREST image
        log "INFO" "Building pREST image: agentstack/prest:$VERSION"
        docker build \
            -f "$PROJECT_ROOT/Dockerfile.prest-production" \
            -t "agentstack/prest:$VERSION" \
            -t "agentstack/prest:latest" \
            "$PROJECT_ROOT" || error_exit "Failed to build pREST image"
    else
        log "INFO" "DRY RUN: Would build pREST image: agentstack/prest:$VERSION"
    fi

    log "SUCCESS" "Custom images built successfully"
}

# Deploy services
deploy_services() {
    log "STEP" "Deploying services"

    if [ "$DRY_RUN" = false ]; then
        # Start database first
        log "INFO" "Starting database services"
        docker-compose -f "$COMPOSE_FILE" up -d postgres redis || error_exit "Failed to start database services"

        # Wait for database to be ready
        log "INFO" "Waiting for database to be ready"
        local max_wait=60
        local wait_time=0
        while [ $wait_time -lt $max_wait ]; do
            if docker-compose -f "$COMPOSE_FILE" exec -T postgres pg_isready -U "${POSTGRES_USER:-postgres}" >/dev/null 2>&1; then
                break
            fi
            sleep 2
            wait_time=$((wait_time + 2))
        done

        if [ $wait_time -ge $max_wait ]; then
            error_exit "Database failed to become ready within ${max_wait} seconds"
        fi

        # Start application services
        log "INFO" "Starting application services"
        docker-compose -f "$COMPOSE_FILE" up -d pgbouncer prest-api traefik || error_exit "Failed to start application services"

        # Start monitoring services
        log "INFO" "Starting monitoring services"
        docker-compose -f "$COMPOSE_FILE" up -d prometheus grafana jaeger postgres-exporter || error_exit "Failed to start monitoring services"

        log "SUCCESS" "All services deployed successfully"
    else
        log "INFO" "DRY RUN: Would deploy all services"
    fi
}

# Wait for services to be healthy
wait_for_services() {
    log "STEP" "Waiting for services to be healthy"

    local services=("postgres" "pgbouncer" "prest-api" "traefik")
    local health_checks=(
        "pg_isready -U ${POSTGRES_USER:-postgres}"
        "pg_isready -h pgbouncer -p 6432 -U ${POSTGRES_USER:-postgres}"
        "curl -f http://localhost:3000/health"
        "curl -f http://localhost:8080/ping"
    )

    for i in "${!services[@]}"; do
        local service="${services[$i]}"
        local health_check="${health_checks[$i]}"
        local max_wait=120
        local wait_time=0

        log "INFO" "Waiting for $service to be healthy"

        while [ $wait_time -lt $max_wait ]; do
            if docker-compose -f "$COMPOSE_FILE" ps "$service" | grep -q "Up (healthy)"; then
                log "SUCCESS" "$service is healthy"
                break
            fi

            if [ $wait_time -gt 0 ] && [ $((wait_time % 10)) -eq 0 ]; then
                log "INFO" "Still waiting for $service (${wait_time}s elapsed)"
            fi

            sleep 2
            wait_time=$((wait_time + 2))
        done

        if [ $wait_time -ge $max_wait ]; then
            log "ERROR" "$service failed to become healthy within ${max_wait} seconds"
            show_service_logs "$service"
            error_exit "Service health check failed for $service"
        fi
    done

    log "SUCCESS" "All services are healthy"
}

# Show service logs
show_service_logs() {
    local service="$1"
    log "INFO" "Showing recent logs for $service:"
    docker-compose -f "$COMPOSE_FILE" logs --tail=50 "$service" || true
}

# Run post-deployment tests
run_tests() {
    log "STEP" "Running post-deployment tests"

    # Test API endpoint
    log "INFO" "Testing API endpoint"
    if curl -f -s http://localhost:3000/health >/dev/null 2>&1; then
        log "SUCCESS" "API endpoint test passed"
    else
        error_exit "API endpoint test failed"
    fi

    # Test database connection
    log "INFO" "Testing database connection"
    if docker-compose -f "$COMPOSE_FILE" exec -T postgres psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-agentstack}" -c "SELECT 1;" >/dev/null 2>&1; then
        log "SUCCESS" "Database connection test passed"
    else
        error_exit "Database connection test failed"
    fi

    # Test metrics endpoint
    log "INFO" "Testing metrics endpoint"
    if curl -f -s http://localhost:3000/metrics >/dev/null 2>&1; then
        log "SUCCESS" "Metrics endpoint test passed"
    else
        log "WARN" "Metrics endpoint test failed"
    fi

    log "SUCCESS" "Post-deployment tests completed"
}

# Rollback deployment
rollback_deployment() {
    if [ "$ROLLBACK_ENABLED" = false ]; then
        return 0
    fi

    log "STEP" "Rolling back deployment"

    if [ -z "$PREVIOUS_VERSION" ] || [ "$PREVIOUS_VERSION" = "none" ]; then
        error_exit "No previous version found for rollback"
    fi

    log "INFO" "Rolling back to version: $PREVIOUS_VERSION"

    if [ "$DRY_RUN" = false ]; then
        # Stop current services
        docker-compose -f "$COMPOSE_FILE" down prest-api || error_exit "Failed to stop current services"

        # Deploy previous version
        export IMAGE_VERSION="$PREVIOUS_VERSION"
        deploy_services
        wait_for_services
        run_tests

        log "SUCCESS" "Rollback completed successfully"
    else
        log "INFO" "DRY RUN: Would rollback to version: $PREVIOUS_VERSION"
    fi
}

# Cleanup old resources
cleanup_resources() {
    log "STEP" "Cleaning up old resources"

    # Remove unused Docker images
    log "INFO" "Removing unused Docker images"
    docker image prune -f >/dev/null 2>&1 || log "WARN" "Failed to prune Docker images"

    # Remove old containers
    log "INFO" "Removing old containers"
    docker container prune -f >/dev/null 2>&1 || log "WARN" "Failed to prune containers"

    # Clean up old backups (keep last 10)
    local backup_dir="$PROJECT_ROOT/backups/$ENVIRONMENT"
    if [ -d "$backup_dir" ]; then
        cd "$backup_dir"
        ls -t *.sql.gz 2>/dev/null | tail -n +11 | xargs -r rm -f
        log "INFO" "Cleaned up old backups"
    fi

    log "SUCCESS" "Resource cleanup completed"
}

# Send notification
send_notification() {
    local status="$1"
    local message="$2"

    # Slack notification (if webhook is configured)
    if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
        local color="good"
        [ "$status" = "failed" ] && color="danger"

        curl -X POST -H 'Content-type: application/json' \
            --data "{\"text\":\"AgentStack pREST Deployment $status\",\"attachments\":[{\"color\":\"$color\",\"text\":\"$message\",\"fields\":[{\"title\":\"Environment\",\"value\":\"$ENVIRONMENT\",\"short\":true},{\"title\":\"Version\",\"value\":\"$VERSION\",\"short\":true},{\"title\":\"Deployment ID\",\"value\":\"$DEPLOYMENT_ID\",\"short\":true}]}]}" \
            "$SLACK_WEBHOOK_URL" >/dev/null 2>&1 || log "WARN" "Failed to send Slack notification"
    fi

    # Email notification (if configured)
    if [ -n "${EMAIL_SMTP_HOST:-}" ] && [ -n "${EMAIL_TO:-}" ]; then
        echo "$message" | mail -s "AgentStack pREST Deployment $status" "$EMAIL_TO" \
            -a "From: ${EMAIL_FROM:-deployments@agentstack.local}" \
            -a "SMTP: ${EMAIL_SMTP_HOST}:${EMAIL_SMTP_PORT:-587}" \
            -a "AUTH: ${EMAIL_SMTP_USER}:${EMAIL_SMTP_PASSWORD}" \
            || log "WARN" "Failed to send email notification"
    fi

    log "INFO" "Notifications sent"
}

# Generate deployment report
generate_report() {
    local status="$1"
    local report_file="$PROJECT_ROOT/reports/deployment-${ENVIRONMENT}-$(date +%Y%m%d-%H%M%S).json"

    mkdir -p "$PROJECT_ROOT/reports"

    cat > "$report_file" << EOF
{
    "deployment_id": "$DEPLOYMENT_ID",
    "environment": "$ENVIRONMENT",
    "version": "$VERSION",
    "previous_version": "$PREVIOUS_VERSION",
    "status": "$status",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "backup_enabled": $BACKUP_ENABLED,
    "backup_file": "$BACKUP_FILE",
    "dry_run": $DRY_RUN,
    "config_file": "$CONFIG_FILE",
    "services": $(docker-compose -f "$COMPOSE_FILE" ps --format json | jq -c '.')
}
EOF

    log "INFO" "Deployment report generated: $report_file"
}

# Main deployment function
main() {
    log "INFO" "Starting AgentStack pREST deployment"
    log "INFO" "Environment: $ENVIRONMENT"
    log "INFO" "Version: $VERSION"
    log "INFO" "Dry run: $DRY_RUN"

    # Create log directory
    mkdir -p "$PROJECT_ROOT/logs"

    # Run deployment steps
    parse_arguments "$@"
    validate_arguments
    load_environment
    check_prerequisites
    get_current_version

    if [ "$ROLLBACK_ENABLED" = true ]; then
        rollback_deployment
        generate_report "rolled_back"
        send_notification "rolled_back" "Deployment rolled back to version $PREVIOUS_VERSION"
        exit 0
    fi

    create_backup
    pull_images
    build_images
    deploy_services
    wait_for_services
    run_tests
    cleanup_resources

    # Success
    generate_report "success"
    send_notification "success" "Deployment completed successfully for version $VERSION"
    log "SUCCESS" "Deployment completed successfully"

    # Show deployment summary
    echo
    echo "=== DEPLOYMENT SUMMARY ==="
    echo "Environment: $ENVIRONMENT"
    echo "Version: $VERSION"
    echo "Previous Version: $PREVIOUS_VERSION"
    echo "Deployment ID: $DEPLOYMENT_ID"
    echo "Backup: ${BACKUP_FILE:-N/A}"
    echo "Services:"
    docker-compose -f "$COMPOSE_FILE" ps
    echo
    echo "=== ACCESS URLs ==="
    echo "pREST API: https://api.agentstack.local:3000"
    echo "Traefik Dashboard: https://traefik.agentstack.local:8080"
    echo "Grafana: https://grafana.agentstack.local:3001"
    echo "Prometheus: https://prometheus.agentstack.local:9090"
    echo "Jaeger: https://jaeger.agentstack.local:16686"
    echo
}

# Execute main function with all arguments
main "$@"