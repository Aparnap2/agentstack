# AgentStack OSS - Production pREST API Guide

## Overview

This guide provides comprehensive instructions for deploying and managing the production-grade pREST API container for AgentStack OSS. The implementation includes advanced security, monitoring, performance optimization, and enterprise-grade features.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Prerequisites](#prerequisites)
3. [Quick Start](#quick-start)
4. [Configuration](#configuration)
5. [Security](#security)
6. [Monitoring & Observability](#monitoring--observability)
7. [Performance Optimization](#performance-optimization)
8. [Deployment](#deployment)
9. [Troubleshooting](#troubleshooting)
10. [Maintenance](#maintenance)
11. [Best Practices](#best-practices)
12. [Appendix](#appendix)

## Architecture Overview

### Components

The production pREST API deployment consists of the following components:

#### Core Services
- **PostgreSQL**: Primary database with pgvector extension for vector operations
- **PgBouncer**: Connection pooling for optimal database performance
- **pREST API**: Production-grade REST API service with advanced features
- **Traefik**: API gateway with load balancing, SSL termination, and security features

#### Monitoring & Observability
- **Prometheus**: Metrics collection and storage
- **Grafana**: Visualization and dashboards
- **Jaeger**: Distributed tracing
- **PostgreSQL Exporter**: Database metrics
- **Redis**: Caching and session storage

#### Security & Infrastructure
- **SSL/TLS**: End-to-end encryption
- **Authentication**: JWT, OAuth2, and API key support
- **Authorization**: Role-based access control (RBAC)
- **Rate Limiting**: Request throttling and DDoS protection
- **CORS**: Cross-origin resource sharing configuration

### Network Architecture

```
Internet → Traefik (Port 443/80) → pREST API (Port 3000)
                                    ↓
                              PgBouncer (Port 6432)
                                    ↓
                           PostgreSQL (Port 5432)

Monitoring Stack:
Grafana (Port 3001) → Prometheus (Port 9090) → Services
Jaeger (Port 16686) → Distributed Tracing
```

## Prerequisites

### System Requirements

#### Minimum Requirements
- **CPU**: 4 cores
- **Memory**: 8GB RAM
- **Storage**: 50GB SSD
- **Network**: 1Gbps

#### Recommended Requirements
- **CPU**: 8 cores
- **Memory**: 16GB RAM
- **Storage**: 100GB SSD
- **Network**: 10Gbps

### Software Requirements

- **Docker**: 20.10+
- **Docker Compose**: 2.0+
- **OpenSSL**: 1.1.1+
- **jq**: 1.6+
- **curl**: 7.64+
- **git**: 2.25+

### SSL Certificates

Production deployments require valid SSL certificates. Options include:
- Let's Encrypt (recommended)
- Commercial CA certificates
- Internal PKI certificates

## Quick Start

### 1. Clone and Setup

```bash
# Clone the repository
git clone https://github.com/agentstack/agentstack-oss.git
cd agentstack-oss

# Copy production configuration
cp .env.production .env

# Generate secure passwords
./scripts/deployment/generate-passwords.sh
```

### 2. Configure Environment

Edit `.env` file with your production values:

```bash
# Database Configuration
POSTGRES_PASSWORD=your_secure_password_here
POSTGRES_DB=agentstack

# JWT Configuration
JWT_SECRET=your_256_bit_secret_key_here

# SSL Configuration
LETSENCRYPT_EMAIL=admin@yourdomain.com

# Monitoring Configuration
GRAFANA_ADMIN_PASSWORD=your_grafana_password
```

### 3. Deploy

```bash
# Make scripts executable
chmod +x scripts/deployment/*.sh
chmod +x scripts/prest/*.sh

# Validate configuration
./scripts/deployment/validate-prest-config.sh --env production

# Deploy to production
./scripts/deployment/deploy-prest-production.sh --env production --backup
```

### 4. Access Services

After deployment, access the services at:

- **pREST API**: https://api.yourdomain.com
- **Traefik Dashboard**: https://traefik.yourdomain.com
- **Grafana**: https://grafana.yourdomain.com
- **Prometheus**: https://prometheus.yourdomain.com
- **Jaeger**: https://jaeger.yourdomain.com

## Configuration

### Environment Variables

Key environment variables for production deployment:

#### Database Configuration
```bash
POSTGRES_USER=postgres
POSTGRES_PASSWORD=your_secure_password
POSTGRES_DB=agentstack
POSTGRES_SSL_MODE=require
POSTGRES_HOST_AUTH_METHOD=scram-sha-256
```

#### Performance Tuning
```bash
POSTGRES_SHARED_BUFFERS=256MB
POSTGRES_WORK_MEM=16MB
POSTGRES_MAINTENANCE_WORK_MEM=128MB
POSTGRES_EFFECTIVE_CACHE_SIZE=1GB
POSTGRES_MAX_CONNECTIONS=200
```

#### pREST Configuration
```bash
PREST_AUTH_ENABLED=true
PREST_AUTH_TYPE=jwt
PREST_JWT_KEY=your_256_bit_secret_key
PREST_SSL_MODE=require
PREST_CACHE_ENABLED=true
PREST_METRICS_ENABLED=true
```

#### Security Configuration
```bash
PREST_CORS_ALLOW_ORIGIN=https://yourdomain.com
PREST_RATE_LIMIT=1000
PREST_RATE_LIMIT_WINDOW=3600
PREST_SECURITY_HEADERS=true
```

#### Monitoring Configuration
```bash
OTEL_ENABLED=true
OTEL_EXPORTER_OTLP_ENDPOINT=http://jaeger:4317
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=secure_password
```

### pREST Configuration File

The main configuration is in `config/prest/prest.toml`:

```toml
[server]
host = "0.0.0.0"
port = 3000
read_timeout = 30
write_timeout = 30

[server.tls]
enabled = true
cert_file = "/opt/prest/ssl/server.crt"
key_file = "/opt/prest/ssl/server.key"
ca_file = "/opt/prest/ssl/ca.crt"

[database]
host = "pgbouncer"
port = 6432
user = "postgres"
pass = "${PREST_PG_PASS}"
database = "agentstack"
ssl_mode = "require"

[auth]
enabled = true
default_type = "jwt"

[auth.jwt]
secret = "${PREST_JWT_KEY}"
algo = "HS256"
expires_in = 3600

[security]
headers_enabled = true
rate_limiting_enabled = true
cors_enabled = true

[monitoring]
enabled = true
metrics_enabled = true
tracing_enabled = true
```

### SSL Configuration

#### Let's Encrypt Setup

1. **Install Certbot**:
```bash
sudo apt-get update
sudo apt-get install certbot
```

2. **Generate Certificates**:
```bash
sudo certbot certonly --standalone -d api.yourdomain.com
```

3. **Configure Paths**:
```bash
PREST_SSL_CERT="/etc/letsencrypt/live/api.yourdomain.com/fullchain.pem"
PREST_SSL_KEY="/etc/letsencrypt/live/api.yourdomain.com/privkey.pem"
PREST_SSL_CA="/etc/letsencrypt/live/api.yourdomain.com/chain.pem"
```

## Security

### Authentication Methods

#### JWT Authentication
- **Secret**: Minimum 256-bit key
- **Algorithm**: HS256 (recommended) or RS256
- **Expiration**: Configurable (default: 1 hour)
- **Refresh Token**: Optional 7-day refresh

#### OAuth2 Integration
Supported providers:
- Google
- GitHub
- Microsoft
- Custom OAuth2 providers

#### API Key Authentication
- **Header**: `X-API-Key`
- **Query Parameter**: `api_key`
- **Cookie**: `prest_api_key`

### Authorization

#### Role-Based Access Control (RBAC)
- **Roles**: admin, manager, user, viewer, anonymous
- **Permissions**: read, write, delete, admin
- **Hierarchy**: Enforced role inheritance

#### Table-Level Security
- **Default Access**: Deny all
- **Excluded Tables**: secrets, tokens, sessions
- **Read-Only Tables**: audit_logs, system_configs

#### Row-Level Security (RLS)
- **User ID Column**: user_id
- **Role ID Column**: role_id
- **Tenant ID Column**: tenant_id

### Security Headers

Configured security headers:
- **Content Security Policy**: Prevents XSS attacks
- **X-Frame-Options**: Prevents clickjacking
- **X-Content-Type-Options**: Prevents MIME sniffing
- **Strict Transport Security**: Forces HTTPS
- **Referrer Policy**: Controls referrer information

### Rate Limiting

Rate limiting configuration:
- **Default Limit**: 1000 requests/hour
- **Burst Capacity**: 100 requests
- **Per-Endpoint Limits**: Configurable
- **IP-based Tracking**: Automatic

### CORS Configuration

Production CORS settings:
- **Allowed Origins**: Restricted list
- **Allowed Methods**: GET, POST, PUT, DELETE, OPTIONS
- **Allowed Headers**: Authorization, Content-Type, X-Requested-With
- **Credentials**: Enabled for authenticated requests

## Monitoring & Observability

### Metrics Collection

#### Prometheus Metrics
- **Request Metrics**: Count, duration, status codes
- **Database Metrics**: Connections, queries, slow queries
- **Cache Metrics**: Hit ratio, size, operations
- **Application Metrics**: Custom business metrics

#### Key Metrics
```promql
# Request rate
rate(prest_requests_total[5m])

# Error rate
rate(prest_requests_failed_total[5m])

# Response time
histogram_quantile(0.95, prest_request_duration_seconds)

# Database connections
prest_database_connections_active
```

### Logging

#### Structured Logging
- **Format**: JSON
- **Fields**: Timestamp, level, method, path, status, duration, user_id
- **Levels**: debug, info, warn, error
- **Output**: Stdout (container), file (host)

#### Log Categories
- **Request Logs**: HTTP request/response details
- **Error Logs**: Application errors and exceptions
- **Audit Logs**: Authentication and authorization events
- **Performance Logs**: Slow queries and performance metrics

### Distributed Tracing

#### Jaeger Integration
- **Sampling Rate**: 10% (configurable)
- **Service Name**: agentstack-prest-api
- **Tags**: Version, environment, service_type

#### Trace Information
- **Request ID**: Unique identifier for each request
- **Trace ID**: Correlates requests across services
- **Span Duration**: Timing for each operation
- **Error Information**: Stack traces and error details

### Health Checks

#### Health Endpoints
- **Basic Health**: `/health` - Service status
- **Detailed Health**: `/health/detailed` - Component status
- **Liveness**: `/health/live` - Container liveness
- **Readiness**: `/health/ready` - Service readiness

#### Health Checks Include
- Database connectivity
- Cache connectivity
- External service dependencies
- SSL certificate validity
- Resource utilization

## Performance Optimization

### Connection Pooling

#### PgBouncer Configuration
- **Pool Mode**: Transaction (recommended)
- **Max Client Connections**: 200
- **Default Pool Size**: 20
- **Server Lifetime**: 1 hour
- **Connection Validation**: Every 30 seconds

#### pREST Connection Pooling
- **Max Open Connections**: 25
- **Max Idle Connections**: 5
- **Connection Lifetime**: 5 minutes
- **Idle Timeout**: 1 minute

### Caching

#### Redis Caching
- **Type**: Redis (distributed) or Memory (local)
- **Default TTL**: 5 minutes
- **Max Memory**: 256MB
- **Eviction Policy**: allkeys-lru

#### Cache Strategy
- **GET Requests**: Cached based on URL and parameters
- **POST/PUT/DELETE**: Cache invalidation
- **User-specific**: Separate cache per user role
- **Time-based**: Automatic expiration

### Query Optimization

#### Database Optimization
- **Connection Pooling**: Reduces connection overhead
- **Query Limits**: Prevents resource exhaustion
- **Batch Operations**: Improves bulk operations
- **Parallel Queries**: Multi-core utilization

#### Application Optimization
- **Response Compression**: GZIP for API responses
- **Request Streaming**: Large payload handling
- **Timeout Configuration**: Prevents hanging requests
- **Memory Management**: Garbage collection tuning

### Resource Limits

#### Container Resources
```yaml
deploy:
  resources:
    limits:
      cpus: "1.0"
      memory: "1G"
    reservations:
      cpus: "0.5"
      memory: "512M"
```

#### Database Resources
```bash
# PostgreSQL tuning
shared_buffers = 256MB
work_mem = 16MB
maintenance_work_mem = 128MB
effective_cache_size = 1GB
max_connections = 200
```

## Deployment

### Pre-Deployment Checklist

#### Security
- [ ] SSL certificates are valid and not expired
- [ ] Environment variables are properly set
- [ ] Security headers are configured
- [ ] Access control lists are defined

#### Performance
- [ ] Resource limits are configured
- [ ] Connection pooling is enabled
- [ ] Caching is configured
- [ ] Monitoring is enabled

#### Backup & Recovery
- [ ] Database backup strategy in place
- [ ] SSL certificates backed up
- [ ] Configuration files backed up
- [ ] Rollback procedure tested

### Deployment Process

#### 1. Validation
```bash
# Validate configuration
./scripts/deployment/validate-prest-config.sh --env production --strict

# Check prerequisites
./scripts/deployment/check-prerequisites.sh --env production
```

#### 2. Backup
```bash
# Create database backup
./scripts/deployment/deploy-prest-production.sh --env production --backup --dry-run

# If all looks good, deploy
./scripts/deployment/deploy-prest-production.sh --env production --backup
```

#### 3. Verification
```bash
# Check service health
curl -f https://api.yourdomain.com/health

# Run smoke tests
./scripts/deployment/smoke-tests.sh --env production

# Verify monitoring
curl -f https://prometheus.yourdomain.com/-/healthy
```

### Blue-Green Deployment

For zero-downtime deployments:

#### 1. Deploy to Green Environment
```bash
# Deploy to staging first
./scripts/deployment/deploy-prest-production.sh --env staging

# Test thoroughly
./scripts/deployment/integration-tests.sh --env staging
```

#### 2. Switch Traffic
```bash
# Update DNS or load balancer
./scripts/deployment/switch-traffic.sh --from blue --to green
```

#### 3. Cleanup
```bash
# Remove old deployment
./scripts/deployment/cleanup-deployment.sh --env blue
```

### Rollback Procedure

#### Immediate Rollback
```bash
# Automatic rollback to previous version
./scripts/deployment/deploy-prest-production.sh --env production --rollback
```

#### Manual Rollback
```bash
# Stop current deployment
docker-compose -f docker-compose.prest-production.yml down prest-api

# Deploy previous version
export IMAGE_VERSION="v1.9.0"
docker-compose -f docker-compose.prest-production.yml up -d prest-api

# Verify rollback
curl -f https://api.yourdomain.com/health
```

## Troubleshooting

### Common Issues

#### Service Not Starting
1. **Check Logs**:
```bash
docker-compose -f docker-compose.prest-production.yml logs prest-api
```

2. **Check Configuration**:
```bash
./scripts/deployment/validate-prest-config.sh --env production
```

3. **Check Dependencies**:
```bash
docker-compose -f docker-compose.prest-production.yml ps
```

#### Database Connection Issues
1. **Check Database Status**:
```bash
docker-compose -f docker-compose.prest-production.yml exec postgres pg_isready
```

2. **Check PgBouncer Status**:
```bash
docker-compose -f docker-compose.prest-production.yml exec pgbouncer psql -h localhost -p 6432 -U postgres -c "SELECT 1;"
```

3. **Check SSL Configuration**:
```bash
docker-compose -f docker-compose.prest-production.yml exec postgres psql "postgresql://postgres:password@localhost:5432/agentstack?sslmode=require" -c "SELECT 1;"
```

#### Performance Issues
1. **Check Resource Usage**:
```bash
docker stats
```

2. **Check Database Performance**:
```bash
# View slow queries
docker-compose -f docker-compose.prest-production.yml exec postgres psql -U postgres -d agentstack -c "SELECT query, mean_time, calls FROM pg_stat_statements ORDER BY mean_time DESC LIMIT 10;"

# Check connections
docker-compose -f docker-compose.prest-production.yml exec postgres psql -U postgres -d agentstack -c "SELECT count(*) FROM pg_stat_activity;"
```

3. **Check Cache Performance**:
```bash
# Redis stats
docker-compose -f docker-compose.prest-production.yml exec redis redis-cli info stats
```

### Debug Mode

Enable debug logging for troubleshooting:

#### Temporary Debug
```bash
# Set debug environment variable
export PREST_DEBUG=true

# Restart service
docker-compose -f docker-compose.prest-production.yml restart prest-api

# View detailed logs
docker-compose -f docker-compose.prest-production.yml logs -f prest-api
```

#### Configuration Debug
```toml
# config/prest/prest.toml
[development]
debug = true
log_level = "debug"
query_logging = true
```

### Log Analysis

#### Common Log Patterns
```bash
# Search for errors
grep "ERROR" /var/log/prest/prest.log

# Search for slow queries
grep "slow query" /var/log/prest/prest.log

# Search for authentication issues
grep "auth" /var/log/prest/prest.log | grep -i "fail\|error"
```

#### Log Aggregation
Use ELK stack or similar for log aggregation:
```yaml
# Example Filebeat configuration
filebeat.inputs:
- type: log
  enabled: true
  paths:
    - /var/log/prest/*.log
  json.keys_under_root: true
  json.add_error_key: true
```

## Maintenance

### Regular Maintenance Tasks

#### Daily
- [ ] Check service health
- [ ] Review error logs
- [ ] Monitor resource usage
- [ ] Verify backup completion

#### Weekly
- [ ] Update SSL certificates
- [ ] Review security patches
- [ ] Analyze performance metrics
- [ ] Check log storage

#### Monthly
- [ ] Database maintenance (VACUUM, ANALYZE)
- [ ] Update dependencies
- [ ] Security audit
- [ ] Capacity planning

### Database Maintenance

#### Automatic Vacuum
```sql
-- Enable autovacuum in postgresql.conf
autovacuum = on
autovacuum_naptime = 30s
autovacuum_vacuum_threshold = 50
autovacuum_analyze_threshold = 50
```

#### Manual Maintenance
```bash
# Connect to database
docker-compose -f docker-compose.prest-production.yml exec postgres psql -U postgres -d agentstack

# Run vacuum
VACUUM ANALYZE;

# Update statistics
ANALYZE;

# Rebuild indexes
REINDEX DATABASE agentstack;
```

### Security Maintenance

#### SSL Certificate Renewal
```bash
# Auto-renew with certbot
sudo certbot renew --quiet

# Or manually
sudo certbot certonly --standalone -d api.yourdomain.com --force-renewal
```

#### Security Updates
```bash
# Update Docker images
docker-compose -f docker-compose.prest-production.yml pull

# Restart services
docker-compose -f docker-compose.prest-production.yml up -d

# Verify functionality
./scripts/deployment/smoke-tests.sh
```

### Backup Strategy

#### Database Backups
```bash
# Automated daily backup
0 2 * * * /path/to/backup-script.sh

# Manual backup
docker-compose -f docker-compose.prest-production.yml exec postgres pg_dump -U postgres agentstack > backup-$(date +%Y%m%d).sql
```

#### Configuration Backups
```bash
# Backup all configurations
tar -czf config-backup-$(date +%Y%m%d).tar.gz \
    config/ \
    .env* \
    docker-compose*.yml \
    scripts/
```

## Best Practices

### Security Best Practices

#### 1. Environment Configuration
- Use strong, unique passwords
- Rotate secrets regularly
- Use environment-specific configurations
- Never commit secrets to version control

#### 2. Network Security
- Implement network segmentation
- Use firewalls and security groups
- Enable SSL/TLS everywhere
- Regular security audits

#### 3. Access Control
- Principle of least privilege
- Regular access reviews
- Multi-factor authentication
- Audit logging

### Performance Best Practices

#### 1. Database Optimization
- Proper indexing strategy
- Connection pooling
- Query optimization
- Regular maintenance

#### 2. Caching Strategy
- Multi-level caching
- Appropriate TTL values
- Cache invalidation
- Monitoring hit ratios

#### 3. Resource Management
- Right-sizing containers
- Resource limits
- Horizontal scaling
- Load balancing

### Operational Best Practices

#### 1. Monitoring
- Comprehensive metrics
- Alerting thresholds
- Log aggregation
- Performance baselines

#### 2. Deployment
- Automated deployments
- Blue-green deployments
- Rollback procedures
- Configuration validation

#### 3. Maintenance
- Regular updates
- Backup procedures
- Documentation
- Incident response

## Appendix

### Configuration Templates

#### Production Environment Template
```bash
# .env.production
POSTGRES_USER=postgres
POSTGRES_PASSWORD=CHANGE_ME_IN_PRODUCTION
POSTGRES_DB=agentstack
JWT_SECRET=CHANGE_ME_256_BIT_SECRET_KEY_HERE
LETSENCRYPT_EMAIL=admin@yourdomain.com
GRAFANA_ADMIN_PASSWORD=CHANGE_ME_GRAFANA_PASSWORD
REDIS_PASSWORD=CHANGE_ME_REDIS_PASSWORD
```

#### Staging Environment Template
```bash
# .env.staging
POSTGRES_USER=postgres
POSTGRES_PASSWORD=staging_password
POSTGRES_DB=agentstack_staging
JWT_SECRET=staging_secret_key_here
LETSENCRYPT_EMAIL=admin@staging.yourdomain.com
GRAFANA_ADMIN_PASSWORD=staging_grafana_password
REDIS_PASSWORD=staging_redis_password
```

### Monitoring Dashboards

#### Grafana Dashboard IDs
- **pREST API Overview**: 12345
- **Database Performance**: 12346
- **Application Metrics**: 12347
- **Infrastructure**: 12348

#### Key Alerts
- High error rate (>5%)
- High response time (>1s)
- Database connection failures
- SSL certificate expiration
- High memory usage (>85%)
- High CPU usage (>90%)

### Troubleshooting Commands

#### Service Management
```bash
# View all services
docker-compose -f docker-compose.prest-production.yml ps

# View service logs
docker-compose -f docker-compose.prest-production.yml logs -f [service-name]

# Restart service
docker-compose -f docker-compose.prest-production.yml restart [service-name]

# Scale service
docker-compose -f docker-compose.prest-production.yml up -d --scale prest-api=3
```

#### Database Operations
```bash
# Connect to database
docker-compose -f docker-compose.prest-production.yml exec postgres psql -U postgres -d agentstack

# View active connections
SELECT * FROM pg_stat_activity;

# View slow queries
SELECT query, mean_time, calls FROM pg_stat_statements ORDER BY mean_time DESC LIMIT 10;

# View table sizes
SELECT schemaname, tablename, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size FROM pg_tables ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
```

### Performance Tuning

#### PostgreSQL Optimization
```sql
-- Performance tuning parameters
ALTER SYSTEM SET shared_buffers = '256MB';
ALTER SYSTEM SET work_mem = '16MB';
ALTER SYSTEM SET maintenance_work_mem = '128MB';
ALTER SYSTEM SET effective_cache_size = '1GB';
ALTER SYSTEM SET max_connections = 200;

-- Apply changes
SELECT pg_reload_conf();
```

#### pREST Optimization
```toml
[performance]
compression_enabled = true
compression_level = 6
default_limit = 1000
max_limit = 10000
timeout = 30

[database]
max_open_conn = 25
max_idle_conn = 5
conn_max_lifetime = 300
```

### Security Scripts

#### SSL Certificate Check
```bash
#!/bin/bash
# check-ssl-certificates.sh

DOMAIN="api.yourdomain.com"
PORT="443"
DAYS_WARNING="30"

EXPIRY_DATE=$(echo | openssl s_client -servername "$DOMAIN" -connect "$DOMAIN:$PORT" 2>/dev/null | openssl x509 -noout -enddate | cut -d= -f2)
EXPIRY_EPOCH=$(date -d "$EXPIRY_DATE" +%s)
CURRENT_EPOCH=$(date +%s)
DAYS_LEFT=$(( (EXPIRY_EPOCH - CURRENT_EPOCH) / 86400 ))

if [ "$DAYS_LEFT" -lt "$DAYS_WARNING" ]; then
    echo "WARNING: SSL certificate for $DOMAIN expires in $DAYS_LEFT days"
    exit 1
else
    echo "OK: SSL certificate for $DOMAIN is valid for $DAYS_LEFT more days"
    exit 0
fi
```

#### Security Audit
```bash
#!/bin/bash
# security-audit.sh

echo "=== Security Audit Report ==="
echo "Date: $(date)"
echo

# Check SSL certificates
echo "1. SSL Certificate Status:"
for domain in api.yourdomain.com grafana.yourdomain.com; do
    ./check-ssl-certificates.sh "$domain"
done

# Check configuration security
echo -e "\n2. Configuration Security:"
./scripts/deployment/validate-prest-config.sh --env production --strict

# Check for exposed secrets
echo -e "\n3. Secret Exposure Check:"
if grep -r "password.*=" config/ | grep -v "\$\|localhost\|example"; then
    echo "WARNING: Potential hardcoded secrets found"
else
    echo "OK: No hardcoded secrets found"
fi
```

## Support and Resources

### Documentation
- [pREST Official Documentation](https://docs.prestd.com/)
- [PostgreSQL Documentation](https://www.postgresql.org/docs/)
- [Traefik Documentation](https://doc.traefik.io/traefik/)
- [Prometheus Documentation](https://prometheus.io/docs/)
- [Grafana Documentation](https://grafana.com/docs/)

### Community Support
- [GitHub Issues](https://github.com/agentstack/agentstack-oss/issues)
- [Discord Community](https://discord.gg/agentstack)
- [Stack Overflow](https://stackoverflow.com/questions/tagged/agentstack-prest)

### Professional Support
For enterprise support and custom implementations:
- Email: support@agentstack.local
- Documentation: https://docs.agentstack.local
- Status Page: https://status.agentstack.local

---

**Version**: 2.0.0
**Last Updated**: 2025-12-01
**Maintainer**: AgentStack OSS Team
**License**: MIT