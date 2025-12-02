#!/bin/bash
# =============================================================================
# AgentStack OSS - PostgreSQL Production Entrypoint Script
# Version: 1.0.0
# Description: Secure and robust PostgreSQL startup with production optimizations
# =============================================================================

set -euo pipefail

# Configuration
readonly PGDATA="${PGDATA:-/var/lib/postgresql/data}"
readonly PGUSER="${POSTGRES_USER:-postgres}"
readonly PGPASSWORD="${POSTGRES_PASSWORD:-password}"
readonly PGDATABASE="${POSTGRES_DB:-agentstack}"
readonly PGPORT="${PGPORT:-5432}"
readonly CONFIG_DIR="/opt/agentstack/postgres/config"
readonly SSL_DIR="/opt/agentstack/postgres/ssl"
readonly SCRIPTS_DIR="/opt/agentstack/postgres"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Logging functions
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ENTRYPOINT] $*"
}

log_error() {
    echo -e "${RED}$(date '+%Y-%m-%d %H:%M:%S') [ENTRYPOINT] ERROR: $*${NC}"
}

log_warning() {
    echo -e "${YELLOW}$(date '+%Y-%m-%d %H:%M:%S') [ENTRYPOINT] WARNING: $*${NC}"
}

log_success() {
    echo -e "${GREEN}$(date '+%Y-%m-%d %H:%M:%S') [ENTRYPOINT] SUCCESS: $*${NC}"
}

log_info() {
    echo -e "${BLUE}$(date '+%Y-%m-%d %H:%M:%S') [ENTRYPOINT] INFO: $*${NC}"
}

# Error handling
trap 'log_error "Entrypoint failed at line $LINENO"' ERR
trap 'log_info "Container stopping..."; pg_ctl -D "$PGDATA" -l "$PGDATA/log/postgresql.log" -m fast stop || true' SIGTERM SIGINT

# Ensure script is running as postgres user
check_user() {
    if [[ "$(id -u)" != "$(id -u postgres)" ]]; then
        log_error "This script must be run as postgres user"
        exit 1
    fi
    log_success "Running as postgres user"
}

# Setup secure SSL configuration if not exists
setup_ssl() {
    if [[ ! -f "$SSL_DIR/server.key" ]]; then
        log_info "Setting up SSL certificates for production..."

        mkdir -p "$SSL_DIR"
        chmod 700 "$SSL_DIR"

        # Generate self-signed certificate for development
        # In production, replace with your organization's certificates
        openssl req -new -x509 -days 365 -nodes \
            -keyout "$SSL_DIR/server.key" \
            -out "$SSL_DIR/server.crt" \
            -subj "/C=US/ST=State/L=City/O=AgentStack/OU=Database/CN=localhost" \
            2>/dev/null || {
                log_warning "OpenSSL not available, SSL will be disabled"
                return 0
            }

        # Generate DH parameters (can take time, but essential for security)
        log_info "Generating DH parameters (this may take a few minutes)..."
        openssl dhparam -out "$SSL_DIR/dhparam.pem" 2048 2>/dev/null || {
            log_warning "DH parameters generation failed"
            rm -f "$SSL_DIR/dhparam.pem"
        }

        # Set proper permissions
        chmod 600 "$SSL_DIR/server.key"
        chmod 644 "$SSL_DIR/server.crt"
        chmod 644 "$SSL_DIR/dhparam.pem"

        log_success "SSL certificates generated successfully"
    else
        log_info "SSL certificates already exist"
    fi
}

# Setup database directory and permissions
setup_database_directory() {
    log_info "Setting up PostgreSQL data directory at $PGDATA"

    if [[ ! -d "$PGDATA" ]]; then
        mkdir -p "$PGDATA"
        chmod 700 "$PGDATA"
        log_success "Created PostgreSQL data directory"
    fi

    # Initialize database if not exists
    if [[ ! -f "$PGDATA/PG_VERSION" ]]; then
        log_info "Initializing PostgreSQL database..."

        # Use initdb with production-optimized settings
        initdb -U "$PGUSER" -D "$PGDATA" \
            --encoding=UTF8 \
            --locale=C \
            --data-checksums \
            --auth-host=md5 \
            --auth-local=peer

        log_success "PostgreSQL database initialized"
    else
        log_info "PostgreSQL database already exists"
    fi

    # Ensure correct permissions
    chown -R postgres:postgres "$PGDATA"
    chmod 700 "$PGDATA"
}

# Copy production configuration files
setup_configuration() {
    log_info "Setting up PostgreSQL configuration..."

    # Copy custom configuration if exists
    if [[ -f "$CONFIG_DIR/postgresql.conf" ]]; then
        cp "$CONFIG_DIR/postgresql.conf" "$PGDATA/postgresql.conf"
        log_info "Applied custom postgresql.conf"
    fi

    if [[ -f "$CONFIG_DIR/pg_hba.conf" ]]; then
        cp "$CONFIG_DIR/pg_hba.conf" "$PGDATA/pg_hba.conf"
        log_info "Applied custom pg_hba.conf"
    fi

    if [[ -f "$CONFIG_DIR/pg_ident.conf" ]]; then
        cp "$CONFIG_DIR/pg_ident.conf" "$PGDATA/pg_ident.conf"
        log_info "Applied custom pg_ident.conf"
    fi

    # Set proper permissions
    chmod 600 "$PGDATA/postgresql.conf"
    chmod 600 "$PGDATA/pg_hba.conf"
    chmod 600 "$PGDATA/pg_ident.conf"

    log_success "PostgreSQL configuration setup completed"
}

# Optimize PostgreSQL for vector workloads
optimize_for_vectors() {
    log_info "Applying vector workload optimizations..."

    # Create log directory if not exists
    mkdir -p "$PGDATA/log"
    chown postgres:postgres "$PGDATA/log"

    # Set optimized sysctl parameters if running as privileged container
    if [[ -w /proc/sys/vm/overcommit_memory ]]; then
        echo 1 > /proc/sys/vm/overcommit_memory 2>/dev/null || true
        echo 262144 > /proc/sys/vm/max_map_count 2>/dev/null || true
    fi

    log_success "Vector workload optimizations applied"
}

# Start PostgreSQL server
start_postgresql() {
    log_info "Starting PostgreSQL server..."

    # Start PostgreSQL with custom options
    pg_ctl -D "$PGDATA" \
        -l "$PGDATA/log/postgresql.log" \
        -o "-c config_file=$PGDATA/postgresql.conf" \
        -o "-c hba_file=$PGDATA/pg_hba.conf" \
        -o "-c ident_file=$PGDATA/pg_ident.conf" \
        -o "-c external_pid_file=/var/run/postgresql/postgres.pid" \
        -o "-c unix_socket_directories=/var/run/postgresql" \
        start

    # Wait for PostgreSQL to be ready
    local max_attempts=30
    local attempt=0

    while [[ $attempt -lt $max_attempts ]]; do
        if pg_isready -U "$PGUSER" -p "$PGPORT" -q; then
            log_success "PostgreSQL server is ready"
            return 0
        fi

        sleep 2
        ((attempt++))
        log_info "Waiting for PostgreSQL to be ready... ($attempt/$max_attempts)"
    done

    log_error "PostgreSQL failed to start within timeout"
    cat "$PGDATA/log/postgresql.log" | tail -20
    exit 1
}

# Create database and user if not exists
setup_database_and_user() {
    log_info "Setting up database and users..."

    # Create database if not exists
    if ! psql -U "$PGUSER" -d postgres -p "$PGPORT" -tAc "SELECT 1 FROM pg_database WHERE datname = '$PGDATABASE';" | grep -q 1; then
        createdb -U "$PGUSER" -p "$PGPORT" "$PGDATABASE"
        log_success "Created database: $PGDATABASE"
    fi

    # Set password for postgres user
    psql -U "$PGUSER" -d postgres -p "$PGPORT" -c "ALTER USER \"$PGUSER\" WITH PASSWORD '$PGPASSWORD';"

    # Create additional users for different services
    local users=("prest_user" "monitoring" "backup_user")

    for user in "${users[@]}"; do
        if ! psql -U "$PGUSER" -d "$PGDATABASE" -p "$PGPORT" -tAc "SELECT 1 FROM pg_roles WHERE rolname = '$user';" | grep -q 1; then
            psql -U "$PGUSER" -d "$PGDATABASE" -p "$PGPORT" -c "CREATE USER \"$user\" WITH PASSWORD '$PGPASSWORD';"
            log_success "Created user: $user"
        fi
    done

    log_success "Database and users setup completed"
}

# Run initialization scripts
run_initialization_scripts() {
    log_info "Running database initialization scripts..."

    local init_scripts_dir="/docker-entrypoint-initdb.d"

    if [[ -d "$init_scripts_dir" ]]; then
        for script in "$init_scripts_dir"/*.sql; do
            if [[ -f "$script" ]]; then
                log_info "Executing initialization script: $(basename "$script")"
                psql -U "$PGUSER" -d "$PGDATABASE" -p "$PGPORT" -f "$script"
                log_success "Completed: $(basename "$script")"
            fi
        done

        for script in "$init_scripts_dir"/*.sh; do
            if [[ -f "$script" ]]; then
                log_info "Executing initialization script: $(basename "$script")"
                bash "$script"
                log_success "Completed: $(basename "$script")"
            fi
        done
    else
        log_info "No initialization scripts found"
    fi
}

# Final health check
final_health_check() {
    log_info "Performing final health check..."

    if bash "$SCRIPTS_DIR/health-check.sh"; then
        log_success "Final health check passed"
    else
        log_error "Final health check failed"
        exit 1
    fi
}

# Main execution
main() {
    log_info "AgentStack PostgreSQL Production Entrypoint v1.0.0"
    log_info "Starting PostgreSQL initialization..."

    # Perform setup steps
    check_user
    setup_ssl
    setup_database_directory
    setup_configuration
    optimize_for_vectors

    # Start server
    start_postgresql

    # Setup database and users
    setup_database_and_user

    # Run initialization scripts
    run_initialization_scripts

    # Final health check
    final_health_check

    log_success "AgentStack PostgreSQL is ready for production use!"
    log_info "Database: $PGDATABASE"
    log_info "User: $PGUSER"
    log_info "Port: $PGPORT"
    log_info "Data directory: $PGDATA"
    log_info "Connection string: postgresql://$PGUSER:$PGPASSWORD@localhost:$PGPORT/$PGDATABASE"

    # Keep container running
    tail -f "$PGDATA/log/postgresql.log"
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi