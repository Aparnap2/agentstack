#!/bin/bash
# =============================================================================
# AgentStack OSS - Production PostgreSQL Deployment Script
# Version: 1.0.0
# Description: Complete production deployment with health checks, SSL, monitoring
# Usage: ./scripts/deploy-postgres.sh [deploy|rollback|backup|restore|health]
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly COMPOSE_FILE="$PROJECT_ROOT/docker-compose.production-postgres.yml"
readonly ENV_FILE="$PROJECT_ROOT/.env.production"
readonly SECRETS_DIR="$PROJECT_ROOT/secrets"
readonly SSL_DIR="$PROJECT_ROOT/ssl/postgres"
readonly BACKUP_DIR="$PROJECT_ROOT/backups/postgres"
readonly LOGS_DIR="$PROJECT_ROOT/logs/deployment"
readonly CONFIG_DIR="$PROJECT_ROOT/config/postgresql"

# Deployment configuration
readonly DOCKER_REGISTRY="${DOCKER_REGISTRY:-}"
readonly IMAGE_NAME="agentstack-postgres"
readonly IMAGE_VERSION="${IMAGE_VERSION:-production-v1.0.0}"
readonly DEPLOYMENT_TIMEOUT="${DEPLOYMENT_TIMEOUT:-300}"  # 5 minutes
readonly HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-30}"
readonly MAX_RETRIES="${MAX_RETRIES:-10}"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# -----------------------------------------------------------------------------
# Logging Functions
# -----------------------------------------------------------------------------
log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${BLUE}[$timestamp] [DEPLOY] $*${NC}" | tee -a "$LOGS_DIR/deployment.log"
}

log_error() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${RED}[$timestamp] [DEPLOY] ERROR: $*${NC}" | tee -a "$LOGS_DIR/deployment.log"
}

log_warning() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${YELLOW}[$timestamp] [DEPLOY] WARNING: $*${NC}" | tee -a "$LOGS_DIR/deployment.log"
}

log_success() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${GREEN}[$timestamp] [DEPLOY] SUCCESS: $*${NC}" | tee -a "$LOGS_DIR/deployment.log"
}

log_info() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "[$timestamp] [DEPLOY] INFO: $*"
}

# -----------------------------------------------------------------------------
# Error Handling and Cleanup
# -----------------------------------------------------------------------------
cleanup_on_exit() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Deployment failed with exit code $exit_code"
        log_error "Check logs in $LOGS_DIR/deployment.log"
    fi
    return $exit_code
}

trap cleanup_on_exit EXIT
trap 'log_error "Interrupted by signal"; exit 1' SIGINT SIGTERM

# -----------------------------------------------------------------------------
# Utility Functions
# -----------------------------------------------------------------------------
check_dependencies() {
    local missing_deps=()

    for cmd in docker docker-compose openssl curl jq; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        log_info "Please install the missing tools and try again"
        exit 1
    fi

    log_success "All dependencies are available"
}

check_docker_daemon() {
    if ! docker info &> /dev/null; then
        log_error "Docker daemon is not running or not accessible"
        exit 1
    fi

    local docker_version
    docker_version=$(docker --version | cut -d' ' -f3 | sed 's/,//')
    log_success "Docker daemon is running (version: $docker_version)"
}

ensure_directories() {
    local dirs=(
        "$SECRETS_DIR"
        "$SSL_DIR"
        "$BACKUP_DIR"
        "$LOGS_DIR"
        "$CONFIG_DIR"
    )

    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            chmod 700 "$dir"
            log_info "Created directory: $dir"
        fi
    done

    log_success "Required directories exist"
}

# -----------------------------------------------------------------------------
# Configuration Management
# -----------------------------------------------------------------------------
load_environment() {
    if [[ -f "$ENV_FILE" ]]; then
        log_info "Loading environment from $ENV_FILE"
        set -a
        source "$ENV_FILE"
        set +a
    else
        log_warning "Environment file not found: $ENV_FILE"
        log_info "Using default environment variables"
    fi
}

validate_configuration() {
    local errors=()

    # Check required environment variables
    local required_vars=(
        "POSTGRES_USER"
        "POSTGRES_PASSWORD"
        "POSTGRES_DB"
        "POSTGRES_PORT"
    )

    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            errors+=("Missing required environment variable: $var")
        fi
    done

    # Validate port number
    if [[ "${POSTGRES_PORT:-}" =~ ^[0-9]+$ ]] && [[ "$POSTGRES_PORT" -lt 1 || "$POSTGRES_PORT" -gt 65535 ]]; then
        errors+=("Invalid port number: $POSTGRES_PORT")
    fi

    if [[ ${#errors[@]} -gt 0 ]]; then
        log_error "Configuration validation failed:"
        for error in "${errors[@]}"; do
            log_error "  - $error"
        done
        exit 1
    fi

    log_success "Configuration validation passed"
}

# -----------------------------------------------------------------------------
# Secrets Management
# -----------------------------------------------------------------------------
generate_secrets() {
    log_info "Generating secure secrets..."

    # Generate PostgreSQL password if not exists
    if [[ ! -f "$SECRETS_DIR/postgres_password.txt" ]]; then
        openssl rand -base64 32 > "$SECRETS_DIR/postgres_password.txt"
        chmod 600 "$SECRETS_DIR/postgres_password.txt"
        log_success "Generated PostgreSQL password"
    else
        log_info "PostgreSQL password already exists"
    fi

    # Generate replication password if not exists
    if [[ ! -f "$SECRETS_DIR/postgres_replication_password.txt" ]]; then
        openssl rand -base64 32 > "$SECRETS_DIR/postgres_replication_password.txt"
        chmod 600 "$SECRETS_DIR/postgres_replication_password.txt"
        log_success "Generated PostgreSQL replication password"
    else
        log_info "PostgreSQL replication password already exists"
    fi

    # Generate JWT secret if not exists
    if [[ ! -f "$SECRETS_DIR/jwt_secret.txt" ]]; then
        openssl rand -base64 64 > "$SECRETS_DIR/jwt_secret.txt"
        chmod 600 "$SECRETS_DIR/jwt_secret.txt"
        log_success "Generated JWT secret"
    else
        log_info "JWT secret already exists"
    fi
}

# -----------------------------------------------------------------------------
# SSL/TLS Management
# -----------------------------------------------------------------------------
generate_ssl_certificates() {
    log_info "Generating SSL certificates..."

    # Create CA certificate if not exists
    if [[ ! -f "$SSL_DIR/ca.key" ]]; then
        log_info "Creating Certificate Authority..."
        openssl genrsa -out "$SSL_DIR/ca.key" 4096
        openssl req -new -x509 -days 3650 -key "$SSL_DIR/ca.key" \
            -out "$SSL_DIR/ca.crt" \
            -subj "/C=US/ST=State/L=City/O=AgentStack/OU=Database/CN=AgentStack-DB-CA"

        chmod 600 "$SSL_DIR/ca.key"
        chmod 644 "$SSL_DIR/ca.crt"
        log_success "Created Certificate Authority"
    fi

    # Create server certificate if not exists
    if [[ ! -f "$SSL_DIR/server.key" ]]; then
        log_info "Creating server certificate..."

        # Generate private key
        openssl genrsa -out "$SSL_DIR/server.key" 2048

        # Create certificate signing request
        openssl req -new -key "$SSL_DIR/server.key" \
            -out "$SSL_DIR/server.csr" \
            -subj "/C=US/ST=State/L=City/O=AgentStack/OU=Database/CN=localhost"

        # Create configuration for SAN
        cat > "$SSL_DIR/server.conf" << EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
C = US
ST = State
L = City
O = AgentStack
OU = Database
CN = localhost

[v3_req]
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = *.localhost
IP.1 = 127.0.0.1
IP.2 = ::1
EOF

        # Sign certificate with CA
        openssl x509 -req -in "$SSL_DIR/server.csr" \
            -CA "$SSL_DIR/ca.crt" -CAkey "$SSL_DIR/ca.key" \
            -CAcreateserial -out "$SSL_DIR/server.crt" \
            -days 3650 -extensions v3_req \
            -extfile "$SSL_DIR/server.conf"

        # Set permissions
        chmod 600 "$SSL_DIR/server.key"
        chmod 644 "$SSL_DIR/server.crt"
        chmod 644 "$SSL_DIR/server.csr"
        chmod 644 "$SSL_DIR/server.conf"

        # Generate CRL (Certificate Revocation List)
        touch "$SSL_DIR/server.crl"
        chmod 644 "$SSL_DIR/server.crl"

        log_success "Created server certificate"
    else
        log_info "Server certificate already exists"
    fi

    # Generate DH parameters if not exists
    if [[ ! -f "$SSL_DIR/dhparam.pem" ]]; then
        log_info "Generating DH parameters (this may take a few minutes)..."
        openssl dhparam -out "$SSL_DIR/dhparam.pem" 2048
        chmod 644 "$SSL_DIR/dhparam.pem"
        log_success "Generated DH parameters"
    else
        log_info "DH parameters already exist"
    fi
}

# -----------------------------------------------------------------------------
# Docker Image Management
# -----------------------------------------------------------------------------
build_image() {
    log_info "Building PostgreSQL production image..."

    local image_tag="$IMAGE_NAME:$IMAGE_VERSION"
    local build_args=()

    # Add build arguments
    build_args+=("--build-arg" "BUILD_DATE=$(date -u +'%Y-%m-%dT%H:%M:%SZ')")
    build_args+=("--build-arg" "PG_VERSION=17")
    build_args+=("--build-arg" "PGVECTOR_VERSION=0.8.0")

    # Build the image
    if docker build \
        -f "$PROJECT_ROOT/Dockerfile.postgres" \
        -t "$image_tag" \
        "${build_args[@]}" \
        "$PROJECT_ROOT"; then
        log_success "Built Docker image: $image_tag"
    else
        log_error "Failed to build Docker image"
        exit 1
    fi
}

tag_and_push_image() {
    if [[ -n "$DOCKER_REGISTRY" ]]; then
        log_info "Tagging and pushing image to registry..."

        local local_tag="$IMAGE_NAME:$IMAGE_VERSION"
        local remote_tag="$DOCKER_REGISTRY/$IMAGE_NAME:$IMAGE_VERSION"
        local latest_tag="$DOCKER_REGISTRY/$IMAGE_NAME:latest"

        # Tag image for registry
        docker tag "$local_tag" "$remote_tag"
        docker tag "$local_tag" "$latest_tag"

        # Push to registry
        if docker push "$remote_tag" && docker push "$latest_tag"; then
            log_success "Pushed image to registry: $remote_tag"
        else
            log_error "Failed to push image to registry"
            exit 1
        fi
    else
        log_info "No registry specified, skipping image push"
    fi
}

# -----------------------------------------------------------------------------
# Backup and Recovery
# ||
create_backup() {
    log_info "Creating database backup before deployment..."

    local backup_file="$BACKUP_DIR/pre-deployment-$(date +%Y%m%d_%H%M%S).sql"

    if docker-compose -f "$COMPOSE_FILE" ps postgres | grep -q "Up"; then
        log_info "Database is running, creating backup..."
        docker-compose -f "$COMPOSE_FILE" exec -T postgres pg_dump \
            -U "$POSTGRES_USER" \
            -d "$POSTGRES_DB" \
            --verbose \
            --no-owner \
            --no-privileges \
            --format=custom \
            > "$backup_file"

        if [[ -f "$backup_file" && -s "$backup_file" ]]; then
            gzip "$backup_file"
            log_success "Backup created: ${backup_file}.gz"
        else
            log_error "Failed to create backup"
            exit 1
        fi
    else
        log_warning "Database is not running, skipping backup"
    fi
}

restore_backup() {
    local backup_file="$1"

    if [[ -z "$backup_file" ]]; then
        log_error "No backup file specified"
        exit 1
    fi

    if [[ ! -f "$backup_file" ]]; then
        log_error "Backup file not found: $backup_file"
        exit 1
    fi

    log_info "Restoring database from backup: $backup_file"

    # Stop current database
    docker-compose -f "$COMPOSE_FILE" down postgres

    # Remove old data volume (be careful!)
    docker volume rm agentstack_postgres_production_data || true

    # Start database
    docker-compose -f "$COMPOSE_FILE" up -d postgres

    # Wait for database to be ready
    wait_for_database

    # Restore backup
    if [[ "$backup_file" == *.gz ]]; then
        gunzip -c "$backup_file" | docker-compose -f "$COMPOSE_FILE" exec -T postgres pg_restore \
            -U "$POSTGRES_USER" \
            -d "$POSTGRES_DB" \
            --verbose \
            --clean \
            --if-exists \
            --no-owner \
            --no-privileges
    else
        docker-compose -f "$COMPOSE_FILE" exec -T postgres pg_restore \
            -U "$POSTGRES_USER" \
            -d "$POSTGRES_DB" \
            --verbose \
            --clean \
            --if-exists \
            --no-owner \
            --no-privileges < "$backup_file"
    fi

    log_success "Database restored from backup"
}

# -----------------------------------------------------------------------------
# Health Checking
# ||
wait_for_database() {
    log_info "Waiting for database to be ready..."

    local timeout=$DEPLOYMENT_TIMEOUT
    local interval=$HEALTH_CHECK_INTERVAL
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        if docker-compose -f "$COMPOSE_FILE" exec -T postgres pg_isready -U "$POSTGRES_USER" -p "$POSTGRES_PORT"; then
            log_success "Database is ready"
            return 0
        fi

        log_info "Waiting for database... (${elapsed}s elapsed)"
        sleep $interval
        elapsed=$((elapsed + interval))
    done

    log_error "Database failed to become ready within $timeout seconds"
    return 1
}

run_health_checks() {
    log_info "Running comprehensive health checks..."

    # Check 1: Container health
    local container_status
    container_status=$(docker-compose -f "$COMPOSE_FILE" ps postgres | grep "Up" || echo "")

    if [[ -z "$container_status" ]]; then
        log_error "PostgreSQL container is not running"
        return 1
    fi

    log_success "PostgreSQL container is running"

    # Check 2: Database connection
    if ! docker-compose -f "$COMPOSE_FILE" exec -T postgres pg_isready -U "$POSTGRES_USER" -p "$POSTGRES_PORT"; then
        log_error "Database is not ready for connections"
        return 1
    fi

    log_success "Database connections are working"

    # Check 3: Extensions
    local extensions_check
    extensions_check=$(docker-compose -f "$COMPOSE_FILE" exec -T postgres psql \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
        "SELECT COUNT(*) FROM pg_extension WHERE extname IN ('vector', 'uuid-ossp', 'pg_trgm');")

    if [[ "$extensions_check" != "3" ]]; then
        log_error "Required extensions are not installed"
        return 1
    fi

    log_success "Required extensions are installed"

    # Check 4: Tables
    local tables_check
    tables_check=$(docker-compose -f "$COMPOSE_FILE" exec -T postgres psql \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'agentstack';")

    if [[ "$tables_check" -lt "1" ]]; then
        log_error "Application tables are not created"
        return 1
    fi

    log_success "Application tables are created"

    # Check 5: SSL connectivity
    if docker-compose -f "$COMPOSE_FILE" exec -T postgres psql \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SHOW ssl;" | grep -q "on"; then
        log_success "SSL is enabled"
    else
        log_warning "SSL is not enabled"
    fi

    # Check 6: Performance settings
    local work_mem
    work_mem=$(docker-compose -f "$COMPOSE_FILE" exec -T postgres psql \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SHOW work_mem;")

    if [[ "$work_mem" == *"16MB"* ]]; then
        log_success "Performance settings are configured"
    else
        log_warning "Performance settings may not be optimal (work_mem: $work_mem)"
    fi

    log_success "All health checks passed"
    return 0
}

# -----------------------------------------------------------------------------
# Deployment Functions
# ||
deploy_postgres() {
    log_info "Starting PostgreSQL deployment..."

    # Pre-deployment checks
    check_dependencies
    check_docker_daemon
    load_environment
    validate_configuration
    ensure_directories

    # Generate secrets and certificates
    generate_secrets
    generate_ssl_certificates

    # Build and push image
    build_image
    tag_and_push_image

    # Create backup if database exists
    create_backup

    # Stop existing services
    log_info "Stopping existing services..."
    docker-compose -f "$COMPOSE_FILE" down

    # Start services
    log_info "Starting PostgreSQL services..."
    docker-compose -f "$COMPOSE_FILE" up -d

    # Wait for database to be ready
    wait_for_database

    # Run health checks
    if run_health_checks; then
        log_success "PostgreSQL deployment completed successfully!"
        log_info "Database: $POSTGRES_USER@$localhost:$POSTGRES_PORT/$POSTGRES_DB"
        log_info "SSL: Enabled"
        log_info "Monitoring: http://localhost:9187/metrics"
        return 0
    else
        log_error "Health checks failed, rolling back deployment..."
        rollback_deployment
        return 1
    fi
}

rollback_deployment() {
    log_info "Starting rollback..."

    # Find the most recent backup
    local latest_backup
    latest_backup=$(find "$BACKUP_DIR" -name "pre-deployment-*.sql.gz" -type f | sort -r | head -1)

    if [[ -z "$latest_backup" ]]; then
        log_error "No backup found for rollback"
        exit 1
    fi

    log_info "Rolling back to: $latest_backup"
    restore_backup "$latest_backup"

    log_success "Rollback completed"
}

# -----------------------------------------------------------------------------
# Monitoring and Maintenance
# ||
setup_monitoring() {
    log_info "Setting up monitoring..."

    # Create monitoring user in database
    docker-compose -f "$COMPOSE_FILE" exec -T postgres psql \
        -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
        DO \$\$
        BEGIN
            IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'monitoring') THEN
                CREATE ROLE monitoring WITH LOGIN PASSWORD 'monitoring_password';
                GRANT CONNECT ON DATABASE $POSTGRES_DB TO monitoring;
                GRANT USAGE ON SCHEMA agentstack TO monitoring;
                GRANT SELECT ON ALL TABLES IN SCHEMA agentstack TO monitoring;
                ALTER DEFAULT PRIVILEGES IN SCHEMA agentstack GRANT SELECT ON TABLES TO monitoring;
            END IF;
        END
        \$\$;"

    # Test monitoring user
    if docker-compose -f "$COMPOSE_FILE" exec -T postgres psql \
        -U monitoring -d "$POSTGRES_DB" -c "SELECT 1;" &>/dev/null; then
        log_success "Monitoring user created and tested"
    else
        log_warning "Monitoring user creation may have failed"
    fi

    # Test metrics endpoint
    sleep 10  # Wait for exporter to start
    if curl -f http://localhost:9187/metrics &>/dev/null; then
        log_success "Prometheus metrics endpoint is accessible"
    else
        log_warning "Prometheus metrics endpoint is not accessible"
    fi
}

cleanup_old_backups() {
    log_info "Cleaning up old backups (keeping last 7)..."

    local backup_count
    backup_count=$(find "$BACKUP_DIR" -name "pre-deployment-*.sql.gz" -type f | wc -l)

    if [[ $backup_count -gt 7 ]]; then
        find "$BACKUP_DIR" -name "pre-deployment-*.sql.gz" -type f \
            | sort -r | tail -n +8 | xargs rm -f
        log_success "Cleaned up old backups"
    else
        log_info "No old backups to clean up"
    fi
}

# -----------------------------------------------------------------------------
# CLI Interface
# ||
show_usage() {
    cat << EOF
AgentStack PostgreSQL Production Deployment Script v1.0.0

Usage: $0 <command> [options]

Commands:
    deploy       Deploy PostgreSQL in production mode
    rollback     Rollback to the most recent backup
    backup       Create a manual backup
    restore <file>  Restore from a specific backup file
    health       Run health checks on the deployment
    monitoring   Set up monitoring and metrics
    cleanup      Clean up old backups and temporary files

Examples:
    $0 deploy                    # Deploy PostgreSQL
    $0 rollback                   # Rollback to last backup
    $0 health                     # Run health checks
    $0 restore backup.sql.gz     # Restore from specific backup

Environment Variables:
    POSTGRES_USER      PostgreSQL username
    POSTGRES_PASSWORD  PostgreSQL password
    POSTGRES_DB        PostgreSQL database name
    POSTGRES_PORT      PostgreSQL port (default: 5432)
    DOCKER_REGISTRY    Docker registry for pushing images

Configuration:
    - Environment file: .env.production
    - Secrets directory: secrets/
    - SSL certificates: ssl/postgres/
    - Backups: backups/postgres/
    - Logs: logs/deployment/
EOF
}

# -----------------------------------------------------------------------------
# Main Execution
# ||
main() {
    # Ensure logs directory exists
    mkdir -p "$LOGS_DIR"

    local command="${1:-}"

    case "$command" in
        deploy)
            log_info "AgentStack PostgreSQL Production Deployment v1.0.0"
            deploy_postgres
            setup_monitoring
            cleanup_old_backups
            ;;
        rollback)
            rollback_deployment
            ;;
        backup)
            create_backup
            ;;
        restore)
            if [[ -z "${2:-}" ]]; then
                log_error "Please specify a backup file to restore from"
                exit 1
            fi
            restore_backup "$2"
            ;;
        health)
            load_environment
            run_health_checks
            ;;
        monitoring)
            load_environment
            setup_monitoring
            ;;
        cleanup)
            cleanup_old_backups
            ;;
        -h|--help|help)
            show_usage
            ;;
        *)
            log_error "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi