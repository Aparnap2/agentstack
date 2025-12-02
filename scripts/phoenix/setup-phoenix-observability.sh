#!/bin/bash
# =============================================================================
# AgentStack OSS - Phoenix Observability Setup Script
# Version: 1.0.0
# Description: Production setup for Phoenix LLM observability stack
# =============================================================================
# This script sets up the complete Phoenix observability environment with
# PostgreSQL backend, OpenTelemetry collector, Prometheus, and Grafana
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
ENV_FILE="$PROJECT_ROOT/.env.phoenix-observability"
SECRETS_DIR="/opt/agentstack/secrets"
DATA_DIR="/opt/agentstack/data"
LOG_DIR="/opt/agentstack/logs"
CONFIG_DIR="/opt/agentstack/config"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# -----------------------------------------------------------------------------
# Logging Functions
# -----------------------------------------------------------------------------
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------
check_dependencies() {
    log_info "Checking dependencies..."

    # Check if Docker is installed
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed. Please install Docker first."
        exit 1
    fi

    # Check if Docker Compose is installed
    if ! command -v docker-compose &> /dev/null; then
        log_error "Docker Compose is not installed. Please install Docker Compose first."
        exit 1
    fi

    # Check if openssl is installed (for generating secrets)
    if ! command -v openssl &> /dev/null; then
        log_error "OpenSSL is not installed. Please install OpenSSL first."
        exit 1
    fi

    log_success "All dependencies are installed."
}

check_system_resources() {
    log_info "Checking system resources..."

    # Check available memory
    TOTAL_MEMORY=$(free -g | awk '/^Mem:/{print $2}')
    if [ "$TOTAL_MEMORY" -lt 16 ]; then
        log_warning "System has ${TOTAL_MEMORY}GB RAM. Recommended minimum is 16GB for production."
    else
        log_success "System has ${TOTAL_MEMORY}GB RAM. Sufficient for production."
    fi

    # Check available disk space
    AVAILABLE_DISK=$(df -BG /opt 2>/dev/null | awk 'NR==2{print $4}' | sed 's/G//')
    if [ -n "$AVAILABLE_DISK" ] && [ "$AVAILABLE_DISK" -lt 100 ]; then
        log_warning "Only ${AVAILABLE_DISK}GB disk space available. Recommended minimum is 100GB for production."
    else
        log_success "Sufficient disk space available."
    fi

    # Check CPU cores
    CPU_CORES=$(nproc)
    if [ "$CPU_CORES" -lt 8 ]; then
        log_warning "System has ${CPU_CORES} CPU cores. Recommended minimum is 8 for production."
    else
        log_success "System has ${CPU_CORES} CPU cores. Sufficient for production."
    fi
}

create_directories() {
    log_info "Creating directory structure..."

    # Data directories
    sudo mkdir -p "$DATA_DIR/phoenix/postgres"
    sudo mkdir -p "$DATA_DIR/phoenix/app"
    sudo mkdir -p "$DATA_DIR/otel-collector"
    sudo mkdir -p "$DATA_DIR/prometheus"
    sudo mkdir -p "$DATA_DIR/grafana"

    # Backup directories
    sudo mkdir -p "$DATA_DIR/backup/phoenix/wal"
    sudo mkdir -p "$DATA_DIR/backup/postgres/wal"
    sudo mkdir -p "$DATA_DIR/backup/postgres/backups"

    # Secrets directory
    sudo mkdir -p "$SECRETS_DIR"

    # Log directories
    sudo mkdir -p "$LOG_DIR/phoenix"
    sudo mkdir -p "$LOG_DIR/prometheus"
    sudo mkdir -p "$LOG_DIR/grafana"
    sudo mkdir -p "$LOG_DIR/otel-collector"
    sudo mkdir -p "$LOG_DIR/postgres"

    # SSL directories
    sudo mkdir -p "/opt/agentstack/ssl/phoenix"
    sudo mkdir -p "/opt/agentstack/ssl/postgres"

    # Configuration directories
    sudo mkdir -p "$CONFIG_DIR/phoenix/postgresql"
    sudo mkdir -p "$CONFIG_DIR/phoenix/ssl"

    # Set ownership
    sudo chown -R "$USER:$USER" "$DATA_DIR" "$SECRETS_DIR" "$LOG_DIR" "$CONFIG_DIR"

    log_success "Directory structure created."
}

generate_secrets() {
    log_info "Generating secrets..."

    # Phoenix PostgreSQL password
    if [ ! -f "$SECRETS_DIR/phoenix_postgres_password.txt" ]; then
        openssl rand -base64 32 > "$SECRETS_DIR/phoenix_postgres_password.txt"
        log_success "Generated Phoenix PostgreSQL password."
    fi

    # Phoenix API key (for authentication)
    if [ ! -f "$SECRETS_DIR/phoenix_api_key.txt" ]; then
        openssl rand -hex 32 > "$SECRETS_DIR/phoenix_api_key.txt"
        log_success "Generated Phoenix API key."
    fi

    # Phoenix JWT secret
    if [ ! -f "$SECRETS_DIR/phoenix_jwt_secret.txt" ]; then
        openssl rand -base64 64 > "$SECRETS_DIR/phoenix_jwt_secret.txt"
        log_success "Generated Phoenix JWT secret."
    fi

    # Grafana admin password
    if [ ! -f "$SECRETS_DIR/grafana_admin_password.txt" ]; then
        openssl rand -base64 16 > "$SECRETS_DIR/grafana_admin_password.txt"
        log_success "Generated Grafana admin password."
    fi

    # Set secure permissions
    chmod 600 "$SECRETS_DIR"/*.txt

    log_success "All secrets generated with secure permissions."
}

generate_ssl_certificates() {
    log_info "Generating SSL certificates..."

    SSL_DIR="/opt/agentstack/ssl/phoenix"

    # Generate CA key and certificate if not exists
    if [ ! -f "$SSL_DIR/ca.key" ]; then
        openssl genrsa -out "$SSL_DIR/ca.key" 4096
        openssl req -new -x509 -days 3650 -key "$SSL_DIR/ca.key" -out "$SSL_DIR/ca.crt" \
            -subj "/C=US/ST=CA/L=San Francisco/O=AgentStack/OU=Phoenix/CN=AgentStack Phoenix CA"
        log_success "Generated CA certificate."
    fi

    # Generate server key and certificate
    if [ ! -f "$SSL_DIR/server.key" ]; then
        openssl genrsa -out "$SSL_DIR/server.key" 2048
        openssl req -new -key "$SSL_DIR/server.key" -out "$SSL_DIR/server.csr" \
            -subj "/C=US/ST=CA/L=San Francisco/O=AgentStack/OU=Phoenix/CN=localhost"

        # Create certificate config for SAN
        cat > "$SSL_DIR/cert.conf" << EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
C = US
ST = CA
L = San Francisco
O = AgentStack
OU = Phoenix
CN = localhost

[v3_req]
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = phoenix
IP.1 = 127.0.0.1
IP.2 = 172.22.0.20
EOF

        openssl x509 -req -in "$SSL_DIR/server.csr" -CA "$SSL_DIR/ca.crt" -CAkey "$SSL_DIR/ca.key" \
            -CAcreateserial -out "$SSL_DIR/server.crt" -days 3650 -extensions v3_req -extfile "$SSL_DIR/cert.conf"

        log_success "Generated server certificate."
    fi

    # Generate DH parameters
    if [ ! -f "$SSL_DIR/dhparam.pem" ]; then
        openssl dhparam -out "$SSL_DIR/dhparam.pem" 2048
        log_success "Generated DH parameters."
    fi

    # Set secure permissions
    chmod 600 "$SSL_DIR"/*.key
    chmod 644 "$SSL_DIR"/*.crt "$SSL_DIR"/*.pem

    log_success "SSL certificates generated."
}

setup_environment_file() {
    log_info "Setting up environment file..."

    if [ ! -f "$ENV_FILE" ]; then
        cp "$PROJECT_ROOT/.env.phoenix-observability.example" "$ENV_FILE" 2>/dev/null || true
        log_warning "Please create $ENV_FILE with your specific configuration."
    fi

    # Source environment file
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
        log_success "Environment file loaded."
    else
        log_warning "Environment file not found. Using defaults."
    fi
}

initialize_databases() {
    log_info "Initializing databases..."

    # Start Phoenix PostgreSQL temporarily
    cd "$PROJECT_ROOT"
    docker-compose -f docker-compose.phoenix-observability.yml up -d phoenix-postgres

    # Wait for database to be ready
    log_info "Waiting for PostgreSQL to be ready..."
    for i in {1..30}; do
        if docker-compose -f docker-compose.phoenix-observability.yml exec -T phoenix-postgres pg_isready -U phoenix > /dev/null 2>&1; then
            log_success "PostgreSQL is ready."
            break
        fi
        if [ $i -eq 30 ]; then
            log_error "PostgreSQL failed to start within 30 seconds."
            exit 1
        fi
        sleep 1
    done

    # Stop containers
    docker-compose -f docker-compose.phoenix-observability.yml down

    log_success "Database initialization completed."
}

create_systemd_service() {
    log_info "Creating systemd service..."

    cat > /tmp/phoenix-observability.service << EOF
[Unit]
Description=AgentStack Phoenix Observability Stack
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$PROJECT_ROOT
ExecStart=/usr/bin/docker-compose -f docker-compose.phoenix-observability.yml up -d
ExecStop=/usr/bin/docker-compose -f docker-compose.phoenix-observability.yml down
TimeoutStartSec=300
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF

    sudo mv /tmp/phoenix-observability.service /etc/systemd/system/
    sudo systemctl daemon-reload

    log_success "Systemd service created. Enable with: sudo systemctl enable phoenix-observability"
}

setup_logrotate() {
    log_info "Setting up log rotation..."

    cat > /tmp/phoenix-observability << EOF
/opt/agentstack/logs/phoenix/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 644 $USER $USER
}

/opt/agentstack/logs/prometheus/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 644 $USER $USER
}

/opt/agentstack/logs/grafana/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 644 $USER $USER
}

/opt/agentstack/logs/otel-collector/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 644 $USER $USER
}

/opt/agentstack/logs/postgres/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 644 $USER $USER
}
EOF

    sudo mv /tmp/phoenix-observability /etc/logrotate.d/

    log_success "Log rotation configured."
}

run_health_check() {
    log_info "Running initial health check..."

    cd "$PROJECT_ROOT"
    docker-compose -f docker-compose.phoenix-observability.yml up -d

    # Wait for services to start
    log_info "Waiting for services to start..."
    sleep 30

    # Check Phoenix
    if curl -f http://localhost:6006/health > /dev/null 2>&1; then
        log_success "Phoenix is healthy."
    else
        log_warning "Phoenix health check failed."
    fi

    # Check Prometheus
    if curl -f http://localhost:9090/-/healthy > /dev/null 2>&1; then
        log_success "Prometheus is healthy."
    else
        log_warning "Prometheus health check failed."
    fi

    # Check Grafana
    if curl -f http://localhost:3001/api/health > /dev/null 2>&1; then
        log_success "Grafana is healthy."
    else
        log_warning "Grafana health check failed."
    fi
}

print_access_information() {
    log_info "Phoenix Observability Stack Setup Complete!"
    echo
    echo "Access URLs:"
    echo "  Phoenix UI:             http://localhost:6006"
    echo "  Prometheus Metrics:      http://localhost:9090"
    echo "  Grafana Dashboards:      http://localhost:3001"
    echo "  OpenTelemetry Collector: http://localhost:4317 (gRPC) / 4318 (HTTP)"
    echo
    echo "Credentials:"
    echo "  Grafana Admin:           admin"
    echo "  Grafana Password:        $(cat "$SECRETS_DIR/grafana_admin_password.txt")"
    echo
    echo "Management Commands:"
    echo "  Start services:           docker-compose -f docker-compose.phoenix-observability.yml up -d"
    echo "  Stop services:            docker-compose -f docker-compose.phoenix-observability.yml down"
    echo "  View logs:               docker-compose -f docker-compose.phoenix-observability.yml logs -f [service]"
    echo "  Restart services:         docker-compose -f docker-compose.phoenix-observability.yml restart"
    echo
    echo "Security Notes:"
    echo "  - Secrets are stored in: $SECRETS_DIR"
    echo "  - SSL certificates in:   /opt/agentstack/ssl/phoenix"
    echo "  - Environment file:       $ENV_FILE"
    echo "  - Ensure proper permissions on secrets directory"
    echo
    log_success "Setup completed successfully!"
}

# -----------------------------------------------------------------------------
# Main Execution
# -----------------------------------------------------------------------------
main() {
    log_info "Starting Phoenix Observability Stack Setup..."

    check_dependencies
    check_system_resources
    create_directories
    generate_secrets
    generate_ssl_certificates
    setup_environment_file
    initialize_databases

    # Optional: Create systemd service if running as root
    if [ "$EUID" -eq 0 ]; then
        create_systemd_service
        setup_logrotate
    fi

    run_health_check
    print_access_information

    log_success "Phoenix Observability Stack setup complete!"
}

# Run main function
main "$@"