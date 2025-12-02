# AgentStack OSS

*"The XAMPP for Vertical AI Agents"*

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

AgentStack bundles all the essential infrastructure for building Vertical AI Agents into a single `docker compose up` command, running locally for **$0**.

## 🚀 What It Solves

Building a Vertical AI Agent (e.g., "AI Dental Billing Clerk") traditionally requires:

- **Database** with vector search ($70/mo Pinecone)
- **AI Gateway** for model routing ($50/mo Portkey)
- **Observability** to debug traces ($100/mo Langfuse)
- **Task Queue** for async jobs ($30/mo AWS SQS)
- **Document Parser** for PDFs ($100/mo Unstructured.io)

**Total SaaS Cost:** $350+/month before writing agent code.

AgentStack provides all of this **locally** with open-source alternatives.

## ✨ Features

| Component | Technology | Purpose | Cost |
|-----------|------------|---------|------|
| **AI Gateway** | LiteLLM Proxy | Model routing, load balancing, cost tracking | $0 |
| **Observability** | Arize Phoenix | LLM tracing, latency analysis, prompt comparison | $0 |
| **Database** | PostgreSQL + pgvector | Relational + vector search (1536-dim embeddings) | $0 |
| **REST API** | pREST | Auto-generated REST API from database schema | $0 |
| **Task Queue** | Celery + Valkey | Async document processing, job status tracking | $0 |
| **Document Parser** | Docling (IBM) | PDF/HTML/DOCX → clean Markdown | $0 |
| **Admin UI** | Adminer | Database administration interface | $0 |

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    USER APPLICATION                         │
│                (Next.js, React, Mobile App)                 │
└─────────────────────────┬───────────────────────────────────┘
                          │
                 ┌────────▼────────┐
                 │   LiteLLM        │ ← AI Gateway (Port 4000)
                 │   Gateway        │
                 └────────┬────────┘
                          │ Traces (OTLP)
                 ┌────────▼────────┐
                 │   Phoenix        │ ← Observability (Port 6006)
                 │   Dashboard      │
                 └────────┬────────┘
                          │ SQL
                 ┌────────▼────────┐
                 │ PostgreSQL      │ ← Database (Port 5432)
                 │ + pgvector      │
                 └────────┬────────┘
                          │ Read/Write
                 ┌────────▼────────┐
                 │   Celery        │ ← Async Worker
                 │   Tasks         │
                 └────────┬────────┘
                          │ Jobs
                 ┌────────▼────────┐
                 │   Valkey        │ ← Message Broker (Port 6379)
                 │   (Redis alt)   │
                 └─────────────────┘
```

## 🚀 Quick Start

### Prerequisites
- Docker & Docker Compose
- 2GB+ RAM, 5GB+ disk space
- OpenSSL (for SSL certificates)

### Installation

```bash
# 1. Clone repository
git clone <repository-url>
cd agentstack-oss

# 2. Copy environment template
cp .env.example .env

# 3. Add your OpenAI API key (required)
nano .env
# Set: OPENAI_API_KEY=sk-your-openai-key-here

# 4. Start all services
docker compose up -d --build

# 5. Wait for initialization (2-5 minutes on first run)
docker compose logs -f worker
```

### Verification

| Service | URL | Expected Result |
|---------|-----|-----------------|
| **Phoenix** | http://localhost:6006 | Dashboard loads, shows "Projects" |
| **pREST API** | http://localhost:3000/tables | JSON list of database tables |
| **LiteLLM** | http://localhost:4000/health | `{"status": "healthy"}` |
| **Adminer** | http://localhost:8080 | Login form (postgres/password) |

## 📖 Usage Examples

### Ingest a Document

```python
from celery import Celery

app = Celery(broker='redis://localhost:6379/0')

# Ingest PDF from URL
result = app.send_task(
    'tasks.ingest_document',
    args=['https://example.com/document.pdf'],
    kwargs={'metadata': {'category': 'research'}}
)

# Wait for completion
document = result.get(timeout=120)
print(f"Document ID: {document['document_id']}")
```

### Semantic Search

```python
# Search knowledge base
result = app.send_task(
    'tasks.semantic_search',
    args=['What is machine learning?', 5, 0.7]
)

matches = result.get(timeout=30)
for doc in matches:
    print(f"Match: {doc['filename']} (similarity: {doc['similarity']:.2f})")
```

### RAG Query

```python
# Ask question with context from knowledge base
result = app.send_task(
    'tasks.rag_query',
    args=['Explain quantum computing'],
    kwargs={'model': 'gpt-4o'}
)

response = result.get(timeout=60)
print(response['answer'])
print("Sources:", response['sources'])
```

## 🔧 Configuration

### Environment Variables

```bash
# Required
OPENAI_API_KEY=sk-your-key-here

# Optional
ANTHROPIC_API_KEY=sk-ant-your-key-here
DEFAULT_MODEL=gpt-4o
EMBEDDING_MODEL=text-embedding-3-small

# Database
POSTGRES_USER=postgres
POSTGRES_PASSWORD=password
POSTGRES_DB=agentstack

# Security
JWT_SECRET=change-in-production
```

### Model Configuration

Edit `configs/litellm_config.yaml` to add/remove models:

```yaml
model_list:
  - model_name: gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: os.environ/OPENAI_API_KEY

  - model_name: claude-3-5-sonnet
    litellm_params:
      model: anthropic/claude-3-5-sonnet-20241022
      api_key: os.environ/ANTHROPIC_API_KEY
```

## 🗄️ Database Schema

### Core Tables

- **`knowledge_base`**: Documents + embeddings
- **`chat_sessions`**: Conversation memory
- **`chat_messages`**: Individual messages with tracing
- **`job_status`**: Async task tracking
- **`prompt_templates`**: Reusable prompts

### Vector Search

```sql
-- Search by semantic similarity
SELECT * FROM search_knowledge(
    query_embedding => '[0.1,0.2,...]',
    match_threshold => 0.7,
    match_count => 5
);
```

## 🔍 Observability

All LLM calls are automatically traced in Phoenix:

- **Latency analysis** per model
- **Cost tracking** per request
- **Prompt comparison** across versions
- **Error debugging** with full context

Access Phoenix at: http://localhost:6006

## 🛠️ Development

### Project Structure

```
agentstack-oss/
├── docker-compose.yml          # Main orchestration
├── .env.example               # Environment template
├── configs/
│   └── litellm_config.yaml    # Model routing config
├── init/
│   └── 01_extensions.sql      # Database schema
├── scripts/                   # Utility scripts
└── src/
    └── agentstack_worker/     # Celery worker code
```

### Adding New Tasks

1. Define task in `src/agentstack_worker/tasks.py`
2. Add tracing with Phoenix spans
3. Update database schema if needed
4. Test with `docker compose restart worker`

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests for new functionality
5. Submit a pull request

### Development Setup

```bash
# Install dependencies
pip install -r requirements-dev.txt

# Run tests
pytest

# Lint code
ruff check .
mypy .
```

## 📄 License

Licensed under the Apache License 2.0. See [LICENSE](LICENSE) for details.

## 🙏 Acknowledgments

Built with open-source components:
- [LiteLLM](https://litellm.ai/) - AI Gateway
- [Arize Phoenix](https://phoenix.arize.com/) - Observability
- [pgvector](https://github.com/pgvector/pgvector) - Vector search
- [pREST](https://prestd.com/) - REST API
- [Docling](https://github.com/docling-project/docling) - Document parsing
- [Celery](https://docs.celeryq.dev/) - Task queue

---

**Ready to build your Vertical AI Agent?** Start with `docker compose up` and focus on your agent logic instead of infrastructure.