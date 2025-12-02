# AgentStack OSS - Production PostgreSQL Container

## Overview

This is a production-grade PostgreSQL container optimized for AI/ML workloads with pgvector support, comprehensive monitoring, security features, and disaster recovery capabilities.

### Features

- **🚀 Production Optimized**: Multi-stage Docker build with security patches
- **🔒 Security First**: SSL/TLS, encrypted connections, role-based access control
- **📊 Monitoring Ready**: Prometheus metrics, health checks, performance tuning
- **🧠 AI Optimized**: pgvector 0.8.0 with 1536-dimensional vector support
- **💾 Backup & Recovery**: Automated backups, point-in-time recovery, verification
- **📈 Performance**: HNSW indexing, connection pooling, resource limits
- **🛡️ Enterprise Ready**: Audit logging, data retention, compliance features

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    AgentStack PostgreSQL                        │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────────┐  ┌──────────────────┐  ┌──────────────┐ │
│  │   PostgreSQL    │  │  PostgreSQL      │  │   pgAdmin    │ │
│  │   (Core DB)     │  │  Exporter       │  │  (Optional)  │ │
│  │   Port: 5432    │  │  Port: 9187     │  │  Port: 5050  │ │
│  │   pgvector      │  │  /metrics       │  │  UI Portal   │ │
│  └─────────────────┘  └──────────────────┘  └──────────────┘ │
│                                                                 │
│  ┌─────────────────┐  ┌──────────────────┐  ┌──────────────┐ │
│  │   SSL/TLS       │  │   WAL Archive    │  │   Monitoring │ │
│  │   Encryption    │  │   Backups        │  │   & Logging  │ │
│  │   Certificates  │  │   Point-in-Time  │  │   Health     │ │
│  │   Auto-renewal  │  │   Recovery       │  │   Checks     │ │
│  └─────────────────┘  └──────────────────┘  └──────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

## Quick Start

### 1. Prerequisites

- Docker & Docker Compose
- 2GB+ RAM available
- 5GB+ disk space
- OpenSSL for SSL certificate generation

### 2. Configuration

Copy the environment template and configure:

```bash
cp .env.production .env.production.local
# Edit .env.production.local with your settings
chmod 600 .env.production.local
```

### 3. Deploy

```bash
# Deploy PostgreSQL
./scripts/deploy-postgres.sh deploy

# Check health status
./scripts/deploy-postgres.sh health

# View logs
docker-compose -f docker-compose.production-postgres.yml logs -f postgres
```

### 4. Connect

```bash
# Connection string
postgresql://postgres:PASSWORD@localhost:5432/agentstack

# Using psql
docker-compose -f docker-compose.production-postgres.yml exec postgres psql -U postgres -d agentstack

# Using pgAdmin (optional)
# http://localhost:5050
# Email: admin@agentstack.local
# Password: Your postgres password
```

## Detailed Configuration

### Environment Variables

#### Core Settings
```bash
POSTGRES_USER=postgres                    # Database user
POSTGRES_DB=agentstack                    # Database name
POSTGRES_PORT=5432                        # Port number
POSTGRES_PASSWORD=your_secure_password     # Set via deploy script
```

#### Performance Tuning
```bash
POSTGRES_SHARED_BUFFERS=256MB             # 25% of RAM
POSTGRES_WORK_MEM=16MB                    # Vector calculations
POSTGRES_EFFECTIVE_CACHE_SIZE=1GB         # 75% of RAM
POSTGRES_MAX_CONNECTIONS=200              # Max connections
```

#### Security Settings
```bash
POSTGRES_SSL=on                           # Enable SSL/TLS
POSTGRES_HOST_AUTH_METHOD=scram-sha-256   # Strong authentication
POSTGRES_ROW_SECURITY=on                  # Row-level security
```

### Production Deployment

#### 1. Security Setup
```bash
# Generate secure passwords and certificates
./scripts/deploy-postgres.sh deploy

# This automatically creates:
# - SSL certificates (localhost/development)
# - Encrypted passwords
# - Secure configuration
```

#### 2. Monitoring Setup
```bash
# Start monitoring services
./scripts/deploy-postgres.sh monitoring

# Access metrics
curl http://localhost:9187/metrics

# View dashboard (if enabled)
http://localhost:5050  # pgAdmin
```

#### 3. Backup Configuration
```bash
# Create manual backup
./scripts/deploy-postgres.sh backup

# Verify backup integrity
./scripts/backup-verify.sh verify

# Test restore procedure
./scripts/backup-verify.sh test-restore
```

## Database Schema

### Schemas

- **`agentstack`**: Main application tables
- **`monitoring`**: Performance metrics and analytics
- **`audit`**: Audit logs and change tracking
- **`maintenance`**: Backup and maintenance operations

### Key Tables

#### Knowledge Base
```sql
agentstack.knowledge_base
├── id (UUID)
├── content_markdown (TEXT)
├── embedding (vector(1536))
├── metadata (JSONB)
├── source_url (TEXT)
├── source_type (TEXT)
├── processing_status (TEXT)
└── indexes for vector similarity search
```

#### Chat Sessions
```sql
agentstack.chat_sessions
├── id (UUID)
├── user_id (TEXT)
├── model (TEXT)
├── system_prompt (TEXT)
├── config (JSONB)
└── usage analytics
```

#### Chat Messages
```sql
agentstack.chat_messages
├── id (UUID)
├── session_id (UUID)
├── role (TEXT)  # system, user, assistant, tool
├── content (TEXT)
├── context_embedding (vector(1536))
├── model usage metrics
└── tracing information
```

## Vector Search Optimization

### Index Configuration
```sql
-- HNSW index for similarity search
CREATE INDEX idx_knowledge_base_embedding_hnsw
ON agentstack.knowledge_base
USING hnsw (embedding vector_cosine_ops)
WITH (m = 16, ef_construction = 128, ef = 64);
```

### Search Functions
```sql
-- Advanced similarity search
SELECT * FROM agentstack.search_knowledge_advanced(
    query_embedding => '[0.1,0.2,...]',  -- Your query vector
    p_filters => '{"source_type": "pdf"}',  -- Filters
    p_match_threshold => 0.7,
    p_match_count => 5
);
```

### Performance Tuning

#### Memory Configuration
```bash
# Vector operations memory
POSTGRES_WORK_MEM=16MB                    # Per query
POSTGRES_MAINTENANCE_WORK_MEM=128MB       # Index creation
VECTOR_SIMILARITY_SEARCH_MEMORY=64MB      # Search cache
VECTOR_INDEX_BUILD_MEMORY=128MB          # Index building
```

#### JIT Compilation
```sql
-- Enable for complex calculations
SET jit = on;
SET jit_above_cost = 100000;
SET jit_optimize_above_cost = 500000;
```

## Monitoring & Observability

### Health Checks
```bash
# Docker health check
docker ps --filter name=agentstack-postgres-prod

# Custom health check
./scripts/health-check.sh

# Database connectivity
docker-compose -f docker-compose.production-postgres.yml exec postgres pg_isready -U postgres
```

### Metrics Collection

#### Prometheus Metrics
```bash
# Access metrics endpoint
curl http://localhost:9187/metrics

# Key metrics to monitor
- pg_stat_database_tup_returned
- pg_stat_database_tup_fetched
- pg_stat_database_tup_inserted
- pg_stat_database_tup_updated
- pg_stat_database_tup_deleted
- pg_stat_activity_count
```

#### Performance Views
```sql
-- Session performance
SELECT * FROM monitoring.session_summary;

-- Model performance analytics
SELECT * FROM monitoring.model_performance;

-- Knowledge base usage
SELECT * FROM monitoring.knowledge_base_analytics;
```

### Logging

#### Log Locations
- **Application Logs**: `/var/log/agentstack/postgres/`
- **Deployment Logs**: `logs/deployment/deployment.log`
- **Backup Logs**: `logs/postgres/backup-verify.log`
- **WAL Archive**: `/opt/agentstack/postgres/wal_archive/`

#### Log Configuration
```bash
# Query logging
POSTGRES_LOG_MIN_DURATION_STATEMENT=1000    # Log queries > 1s
POSTGRES_LOG_STATEMENT=ddl                  # Log DDL
POSTGRES_LOG_CHECKPOINTS=on                 # Log checkpoints
POSTGRES_LOG_CONNECTIONS=on                  # Log connections
```

## Backup & Disaster Recovery

### Automated Backups
```bash
# Create backup before deployment
./scripts/deploy-postgres.sh deploy  # Creates automatic backup

# Manual backup
./scripts/deploy-postgres.sh backup

# Backup verification
./scripts/backup-verify.sh all
```

### Point-in-Time Recovery
```bash
# Enable WAL archiving
POSTGRES_ARCHIVE_MODE=on
POSTGRES_ARCHIVE_TIMEOUT=1800  # Archive every 30 minutes

# WAL archive location
/opt/agentstack/postgres/wal_archive/
```

### Restore Procedures
```bash
# List available backups
find backups/postgres/ -name "*.sql.gz" -ls

# Restore from latest backup
./scripts/deploy-postgres.sh rollback

# Restore from specific backup
./scripts/deploy-postgres.sh restore backup-file.sql.gz

# Verify restore
./scripts/backup-verify.sh test-restore
```

### Retention Policies
```bash
# Backup retention
BACKUP_RETENTION_DAYS=30          # Keep 30 days of backups
MAX_WAL_FILES=1000               # Keep 1000 WAL files

# Log retention
LOG_RETENTION_DAYS=90            # Keep 90 days of logs
AUDIT_RETENTION_DAYS=1095        # Keep 3 years of audit logs
```

## Security Configuration

### SSL/TLS Setup
```bash
# Certificate locations
/opt/agentstack/postgres/ssl/
├── server.crt          # Server certificate
├── server.key          # Server private key
├── ca.crt              # Certificate authority
├── server.crl          # Certificate revocation list
└── dhparam.pem         # Diffie-Hellman parameters
```

### Access Control
```bash
# User management
./scripts/deploy-postgres.sh monitoring  # Creates monitoring user

# Default users
- postgres           # Admin user
- monitoring         # Read-only monitoring access
- backup_user        # Backup operations
- prest_user         # API access
```

### Row-Level Security
```sql
-- Enable RLS on sensitive tables
ALTER TABLE agentstack.chat_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE agentstack.chat_messages ENABLE ROW LEVEL SECURITY;

-- Example policy
CREATE POLICY user_sessions_policy ON agentstack.chat_sessions
    FOR ALL TO application_user
    USING (user_id = current_setting('app.current_user_id'));
```

## Performance Optimization

### Connection Management
```bash
# Connection limits
POSTGRES_MAX_CONNECTIONS=200
POSTGRES_SUPERUSER_RESERVED_CONNECTIONS=3

# Resource limits (Docker)
CPU_LIMIT=2.0
MEMORY_LIMIT=2G
CPU_RESERVATION=1.0
MEMORY_RESERVATION=1G
```

### Query Optimization
```sql
-- Enable query performance tracking
CREATE EXTENSION pg_stat_statements;

-- Analyze slow queries
SELECT query, calls, total_time, mean_time
FROM pg_stat_statements
WHERE mean_time > 1000
ORDER BY mean_time DESC
LIMIT 10;
```

### Index Strategy
```sql
-- Vector similarity index (HNSW)
CREATE INDEX idx_knowledge_base_embedding_hnsw
ON agentstack.knowledge_base
USING hnsw (embedding vector_cosine_ops)
WITH (m = 16, ef_construction = 128);

-- Composite indexes for common queries
CREATE INDEX idx_knowledge_base_lookup
ON agentstack.knowledge_base(source_type, created_at DESC)
WHERE is_active = true;
```

## Troubleshooting

### Common Issues

#### Container Won't Start
```bash
# Check logs
docker-compose -f docker-compose.production-postgres.yml logs postgres

# Check resource usage
docker stats agentstack-postgres-prod

# Check disk space
df -h /opt/agentstack/data/postgres
```

#### Connection Issues
```bash
# Test connectivity
docker-compose -f docker-compose.production-postgres.yml exec postgres pg_isready -U postgres

# Check SSL configuration
docker-compose -f docker-compose.production-postgres.yml exec postgres psql "SHOW ssl;"

# Verify permissions
docker-compose -f docker-compose.production-postgres.yml exec postgres psql "\du"
```

#### Performance Issues
```bash
# Check active connections
SELECT count(*) FROM pg_stat_activity WHERE state = 'active';

# Analyze slow queries
SELECT * FROM pg_stat_statements ORDER BY mean_time DESC LIMIT 5;

# Check index usage
SELECT schemaname, tablename, attname, n_distinct, correlation
FROM pg_stats WHERE schemaname = 'agentstack';
```

### Health Diagnostics
```bash
# Run comprehensive health check
./scripts/deploy-postgres.sh health

# Check vector functionality
docker-compose -f docker-compose.production-postgres.yml exec postgres psql -d agentstack -c "SELECT 1 FROM pg_extension WHERE extname = 'vector';"

# Monitor resource usage
docker stats --no-stream agentstack-postgres-prod
```

## Maintenance

### Routine Tasks
```bash
# Daily
./scripts/backup-verify.sh verify      # Verify backups

# Weekly
./scripts/backup-verify.sh test-restore # Test restore
./scripts/backup-verify.sh cleanup     # Clean old files

# Monthly
./scripts/deploy-postgres.sh monitoring # Check monitoring
./scripts/backup-verify.sh report      # Generate report
```

### Updates & Upgrades
```bash
# Update PostgreSQL version
1. Create full backup
2. Update IMAGE_VERSION in .env.production
3. Run deployment: ./scripts/deploy-postgres.sh deploy
4. Verify functionality
5. Update application if needed
```

## Support & Monitoring

### Dashboard URLs
- **PostgreSQL**: `localhost:5432` (internal)
- **Metrics**: `http://localhost:9187/metrics`
- **pgAdmin**: `http://localhost:5050` (optional)
- **Health Checks**: Available via Docker health status

### Log Analysis
```bash
# View recent errors
grep "ERROR" /var/log/agentstack/postgres/*.log | tail -20

# Monitor connection attempts
grep "connection" /var/log/agentstack/postgres/*.log | tail -20

# Track slow queries
grep "duration:" /var/log/agentstack/postgres/*.log | tail -20
```

## Version Information

- **PostgreSQL**: 17
- **pgvector**: 0.8.0
- **Base Image**: Debian 12 (bookworm)
- **AgentStack Version**: 1.0.0

## License

This production PostgreSQL configuration is part of AgentStack OSS and is licensed under the MIT License.

## Contributing

For contributions to this PostgreSQL configuration, please follow the project's contribution guidelines and ensure all changes maintain production security standards.

---

For more information, see the [main AgentStack documentation](../README.md) or contact the development team.