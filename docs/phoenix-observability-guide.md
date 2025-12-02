# AgentStack OSS - Phoenix Observability Implementation Guide

## Overview

This guide documents the implementation of a **production-grade Phoenix observability container** for AgentStack OSS. This comprehensive observability stack provides:

- **LLM Tracing & Monitoring** with Phoenix Arize
- **OpenTelemetry Integration** for standardized telemetry
- **PostgreSQL Backend** for scalable data persistence
- **Prometheus Metrics** for performance monitoring
- **Grafana Dashboards** for visualization
- **Production Security** with SSL/TLS and authentication
- **High-Availability** architecture with health checks
- **Cost Monitoring** for LLM usage optimization

## Architecture

### Components

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   Applications   │───▶│ Otel Collector   │───▶│   Phoenix UI    │
│  (LLM Services)  │    │  (Traces/Metrics)│    │ (Observability) │
└─────────────────┘    └──────────────────┘    └─────────────────┘
                                │                        │
                                ▼                        ▼
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   Grafana       │◀───│   Prometheus     │◀───│ Phoenix PG DB   │
│ (Visualization) │    │  (Metrics Store) │    │  (Traces Store) │
└─────────────────┘    └──────────────────┘    └─────────────────┘
```

### Network Architecture

- **phoenix-network** (172.22.0.0/16): Core Phoenix services
- **monitoring-network** (172.23.0.0/16): Prometheus/Grafana
- **application-network** (172.24.0.0/16): Application integration

## Quick Start

### Prerequisites

- Docker 20.10+
- Docker Compose 2.0+
- 16GB+ RAM minimum (32GB recommended for production)
- 8+ CPU cores minimum (16+ recommended)
- 100GB+ disk space minimum (500GB+ recommended)

### Installation

1. **Clone and navigate to the project:**
   ```bash
   cd /home/aparna/Desktop/agentstack/agentstack-oss
   ```

2. **Run the setup script:**
   ```bash
   ./scripts/phoenix/setup-phoenix-observability.sh
   ```

3. **Start the observability stack:**
   ```bash
   docker-compose -f docker-compose.phoenix-observability.yml up -d
   ```

4. **Access the services:**
   - Phoenix UI: http://localhost:6006
   - Prometheus: http://localhost:9090
   - Grafana: http://localhost:3001
   - OpenTelemetry: http://localhost:4317 (gRPC) / 4318 (HTTP)

## Configuration

### Environment Variables

Key configuration is in `.env.phoenix-observability`:

```bash
# Phoenix Configuration
PHOENIX_HOST=0.0.0.0
PHOENIX_PORT=6006
PHOENIX_PROJECT_NAME=agentstack-production
PHOENIX_SQL_DATABASE_URL="postgresql://phoenix:password@phoenix-postgres:5432/phoenix"

# Performance Tuning
PHOENIX_MAX_WORKERS=4
PHOENIX_MEMORY_LIMIT=6G
PHOENIX_TRACING_SAMPLE_RATE=1.0

# Security
PHOENIX_AUTH_ENABLED=true
PHOENIX_SSL_ENABLED=true
PHOENIX_CORS_ORIGINS=http://localhost:3001,http://localhost:6006
```

### Resource Limits

| Service | CPU Limit | Memory Limit | CPU Reservation | Memory Reservation |
|---------|------------|--------------|-----------------|-------------------|
| Phoenix | 4.0 cores | 6GB | 2.0 cores | 3GB |
| Phoenix PostgreSQL | 3.0 cores | 4GB | 1.5 cores | 2GB |
| OpenTelemetry Collector | 2.0 cores | 2GB | 1.0 core | 1GB |
| Prometheus | 2.0 cores | 4GB | 1.0 core | 2GB |
| Grafana | 1.0 core | 1GB | 0.5 core | 512MB |

## Integration Guide

### LLM Application Integration

#### Python Integration

```python
from phoenix.otel import register
import litellm
import os

# Configure Phoenix tracer
tracer_provider = register(
    project_name="agentstack-production",
    auto_instrument=True
)

# Set API keys
os.environ["OPENAI_API_KEY"] = "your-api-key"

# Use LiteLLM with automatic tracing
response = litellm.completion(
    model="gpt-4",
    messages=[{"role": "user", "content": "Hello!"}]
)
```

#### JavaScript/TypeScript Integration

```typescript
import { NodeSDK } from '@opentelemetry/sdk-node';
import { OTLPTraceExporter } from '@opentelemetry/exporter-otlp-grpc';
import { Resource } from '@opentelemetry/resources';
import { SemanticResourceAttributes } from '@opentelemetry/semantic-conventions';

const sdk = new NodeSDK({
  resource: new Resource({
    [SemanticResourceAttributes.SERVICE_NAME]: 'agentstack-app',
    [SemanticResourceAttributes.DEPLOYMENT_ENVIRONMENT]: 'production',
  }),
  traceExporter: new OTLPTraceExporter({
    url: 'http://localhost:4317',
  }),
});

sdk.start();

// Your LLM application code
```

#### OpenTelemetry Configuration

```yaml
#otel-config.yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  batch:
    timeout: 5s
    send_batch_size: 1024

exporters:
  otlp:
    endpoint: http://phoenix:4317
    headers:
      Authorization: "Bearer ${PHOENIX_API_KEY}"

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [otlp]
```

### Application Configuration

Your applications should send traces to the OpenTelemetry collector:

- **gRPC Endpoint**: `http://localhost:4317`
- **HTTP Endpoint**: `http://localhost:4318`
- **Sample Rate**: 1.0 (100% in production, adjust based on volume)
- **Batch Size**: 1024 traces
- **Timeout**: 30s

## Monitoring and Observability

### Key Metrics

#### Phoenix Core Metrics
- `phoenix_trace_spans_total`: Total number of traces
- `phoenix_trace_duration_seconds`: Request latency
- `phoenix_trace_llm_token_usage_total`: Token consumption
- `phoenix_trace_llm_estimated_cost_usd_total`: Cost tracking

#### Database Metrics
- `pg_stat_activity_count`: Active connections
- `pg_stat_database_xact_commit`: Transaction rate
- `pg_stat_statements_mean_time_ms`: Query performance

#### System Metrics
- `process_cpu_seconds_total`: CPU usage
- `process_resident_memory_bytes`: Memory usage
- `node_filesystem_avail_bytes`: Disk space

### Grafana Dashboards

1. **Phoenix LLM Observability Overview**
   - Request rates by model
   - Response time percentiles
   - Cost and token usage
   - Error rates and distribution

2. **Phoenix Performance Dashboard**
   - System resource utilization
   - Database performance
   - Trace processing rates
   - Queue depth and latency

3. **Phoenix Cost & Usage Dashboard**
   - LLM cost breakdown by model
   - Token consumption trends
   - Cost per request analysis
   - Budget tracking and alerts

### Alerting Rules

Critical alerts are configured for:
- Service downtime (> 1 minute)
- High error rate (> 10%)
- High latency (> 10s P95)
- Memory usage (> 85%)
- Cost thresholds (> $100/hour, > $1000/day)

## Security

### Authentication

- **Phoenix**: JWT-based authentication
- **Grafana**: Admin + role-based access control
- **Prometheus**: Network isolation + optional auth
- **PostgreSQL**: SCRAM-SHA-256 authentication

### SSL/TLS Configuration

- **End-to-end encryption** between all services
- **Custom CA** for internal certificates
- **Certificate rotation** recommended annually
- **Perfect Forward Secrecy** with modern cipher suites

### Network Security

- **Network isolation** with Docker networks
- **Firewall rules** to restrict access
- **VPN access** for remote management
- **API rate limiting** to prevent abuse

## Performance Optimization

### High-Volume Tracing

1. **Sampling Strategy**
   - Start with 100% sampling
   - Implement adaptive sampling based on cost/value
   - Use head-based sampling for high-traffic endpoints

2. **Batch Processing**
   - Optimize batch size (512-1024 traces)
   - Configure timeout (5-10 seconds)
   - Monitor queue depth and latency

3. **Resource Scaling**
   - Vertical scaling for predictable workloads
   - Horizontal scaling for spiky traffic
   - Auto-scaling based on metrics

### Database Optimization

#### PostgreSQL Configuration

```sql
-- Vector search optimization
SET work_mem = '32MB';
SET maintenance_work_mem = '256MB';
SET effective_cache_size = '2GB';

-- Connection optimization
SET max_connections = 300;
SET superuser_reserved_connections = 5;

-- WAL optimization
SET wal_buffers = '32MB';
SET max_wal_size = '2GB';
SET min_wal_size = '160MB';
```

#### Indexing Strategy

```sql
-- Time-based partitioning
CREATE TABLE traces_2024_12 PARTITION OF traces
FOR VALUES FROM ('2024-12-01') TO ('2025-01-01');

-- Vector similarity index
CREATE INDEX CONCURRENTLY traces_embedding_idx
ON traces USING ivfflat (embedding vector_cosine_ops)
WITH (lists = 100);

-- Query performance indexes
CREATE INDEX CONCURRENTLY traces_model_created_idx
ON traces (llm_model, created_at);

CREATE INDEX CONCURRENTLY traces_status_duration_idx
ON traces (status, duration_seconds);
```

### Caching Strategy

1. **Application Caching**
   - Redis for session data
   - Application-level response caching
   - CDN for static assets

2. **Database Caching**
   - PostgreSQL query result cache
   - Connection pooling (PgBouncer)
   - Read replicas for analytical queries

## Backup and Disaster Recovery

### Backup Strategy

1. **Database Backups**
   - **Daily full backups** at 2 AM
   - **Point-in-time recovery** with WAL archiving
   - **Cross-region replication** for disaster recovery
   - **Backup verification** with regular restores

2. **Trace Data Backup**
   - **Cold storage** for old traces
   - **Data retention** policies (90 days default)
   - **Export to S3** for long-term storage

### Disaster Recovery Plan

1. **RTO/RPO**
   - **Recovery Time Objective**: 4 hours
   - **Recovery Point Objective**: 15 minutes
   - **Service Level Agreement**: 99.9% uptime

2. **Failover Procedures**
   - **Manual failover** for planned maintenance
   - **Automatic failover** for service failures
   - **Health check integration** with load balancers

## Troubleshooting

### Common Issues

#### Phoenix Service Not Starting
```bash
# Check logs
docker-compose -f docker-compose.phoenix-observability.yml logs phoenix

# Check database connection
docker-compose exec phoenix-postgres pg_isready -U phoenix

# Verify environment variables
docker-compose exec phoenix env | grep PHOENIX
```

#### High Memory Usage
```bash
# Check memory usage
docker stats phoenix

# Review memory configuration
docker-compose exec phoenix env | grep MEMORY

# Adjust limits in docker-compose.yml
```

#### Traces Not Appearing
```bash
# Check OpenTelemetry collector logs
docker-compose logs otel-collector

# Verify trace sending
curl -X POST http://localhost:4318/v1/traces \
  -H "Content-Type: application/json" \
  -d '{"resourceSpans": []}'

# Check Phoenix health
curl http://localhost:6006/health
```

#### Database Performance Issues
```bash
# Check slow queries
docker-compose exec phoenix-postgres psql -U phoenix -c "
SELECT query, mean_time, calls
FROM pg_stat_statements
ORDER BY mean_time DESC
LIMIT 10;"

# Check active connections
docker-compose exec phoenix-postgres psql -U phoenix -c "
SELECT count(*), state
FROM pg_stat_activity
GROUP BY state;"

# Analyze vacuum statistics
docker-compose exec phoenix-postgres psql -U phoenix -c "
SELECT schemaname, relname, last_vacuum, last_autovacuum
FROM pg_stat_user_tables;"
```

### Log Locations

- **Phoenix**: `/var/log/agentstack/phoenix/`
- **Prometheus**: `/var/log/agentstack/prometheus/`
- **Grafana**: `/var/log/agentstack/grafana/`
- **OpenTelemetry**: `/var/log/agentstack/otel-collector/`
- **PostgreSQL**: `/var/log/agentstack/postgres/`

### Performance Tuning

#### Vertical Scaling
```yaml
# In docker-compose.yml
deploy:
  resources:
    limits:
      cpus: '8.0'
      memory: 12G
    reservations:
      cpus: '4.0'
      memory: 6G
```

#### Horizontal Scaling
```yaml
# Multiple collector instances
otel-collector-1:
  <<: *otel-collector-base
  environment:
    OTEL_RESOURCE_ATTRIBUTES: "service.name=agentstack-otel-collector-1"

otel-collector-2:
  <<: *otel-collector-base
  environment:
    OTEL_RESOURCE_ATTRIBUTES: "service.name=agentstack-otel-collector-2"
```

## Maintenance

### Regular Tasks

#### Daily
- Check service health and logs
- Monitor resource usage and costs
- Review security alerts

#### Weekly
- Update container images
- Review backup completion
- Optimize slow queries

#### Monthly
- Rotate certificates (if needed)
- Update dashboards and alerts
- Review and update documentation

### Updates

#### Container Updates
```bash
# Update to latest versions
docker-compose -f docker-compose.phoenix-observability.yml pull

# Restart with new images
docker-compose -f docker-compose.phoenix-observability.yml up -d

# Verify services
docker-compose -f docker-compose.phoenix-observability.yml ps
```

#### Configuration Updates
```bash
# Update environment variables
vim .env.phoenix-observability

# Restart affected services
docker-compose -f docker-compose.phoenix-observability.yml restart phoenix
```

## Compliance

### Data Privacy
- **GDPR Compliant**: Right to be forgotten
- **Data Minimization**: Collect only necessary data
- **Consent Management**: Explicit opt-in for data collection
- **Data Encryption**: At rest and in transit

### Security Standards
- **SOC 2**: Security controls implementation
- **ISO 27001**: Information security management
- **NIST**: Cybersecurity framework compliance

## Support

### Documentation
- [Phoenix Arize Documentation](https://docs.arize.com/phoenix)
- [OpenTelemetry Documentation](https://opentelemetry.io/docs/)
- [Prometheus Documentation](https://prometheus.io/docs/)
- [Grafana Documentation](https://grafana.com/docs/)

### Community
- [Phoenix GitHub](https://github.com/arize-ai/phoenix)
- [OpenTelemetry Slack](https://cloud-native.slack.com/archives/C01NCTPJRK3)
- [Grafana Community](https://community.grafana.com/)

### Enterprise Support
For enterprise support, contact the maintainers or refer to the support agreements.

---

**Version**: 1.0.0
**Last Updated**: December 2024
**Maintainer**: AgentStack OSS Team