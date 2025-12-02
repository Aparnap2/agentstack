-- =============================================================================
-- AgentStack OSS - Database Initialization Script
-- Version: 1.0.0
-- =============================================================================

-- -----------------------------------------------------------------------------
-- STEP 1: Enable Required Extensions
-- -----------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";      -- UUID generation
CREATE EXTENSION IF NOT EXISTS "vector";          -- pgvector for embeddings
CREATE EXTENSION IF NOT EXISTS "pg_trgm";         -- Fuzzy text search

-- -----------------------------------------------------------------------------
-- STEP 2: Knowledge Base (Documents + Embeddings)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS knowledge_base (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

    -- Source Information
    source_url      TEXT,                         -- Original file URL/path
    source_type     TEXT,                         -- 'pdf', 'docx', 'html', 'text'
    filename        TEXT,                         -- Original filename

    -- Parsed Content
    content_raw     TEXT,                         -- Raw extracted text
    content_markdown TEXT,                        -- Cleaned Markdown (from Docling)
    content_chunks  JSONB DEFAULT '[]',           -- Array of chunks for RAG

    -- Vector Embedding (OpenAI text-embedding-3-small = 1536 dimensions)
    embedding       vector(1536),

    -- Metadata
    metadata        JSONB DEFAULT '{}',           -- Custom key-value pairs
    token_count     INTEGER,                      -- Approximate token count
    char_count      INTEGER,                      -- Character count

    -- Timestamps
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- Index for fast vector similarity search (HNSW algorithm)
CREATE INDEX IF NOT EXISTS idx_knowledge_base_embedding
    ON knowledge_base
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 128);

-- Index for metadata filtering
CREATE INDEX IF NOT EXISTS idx_knowledge_base_metadata
    ON knowledge_base
    USING GIN (metadata);

-- -----------------------------------------------------------------------------
-- STEP 3: Chat Sessions (Conversation Memory)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS chat_sessions (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

    -- User Identification (external ID from your auth system)
    user_id         TEXT,

    -- Session Metadata
    title           TEXT,                         -- Auto-generated or user-set
    system_prompt   TEXT,                         -- Custom system prompt for this session
    model           TEXT DEFAULT 'gpt-4o',        -- Model used in this session

    -- Configuration
    config          JSONB DEFAULT '{}',           -- Temperature, max_tokens, etc.

    -- Timestamps
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_chat_sessions_user
    ON chat_sessions(user_id);

-- -----------------------------------------------------------------------------
-- STEP 4: Chat Messages (Individual Messages)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS chat_messages (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    session_id      UUID REFERENCES chat_sessions(id) ON DELETE CASCADE,

    -- Message Content
    role            TEXT NOT NULL CHECK (role IN ('system', 'user', 'assistant', 'tool')),
    content         TEXT NOT NULL,

    -- Tool Calls (for function calling)
    tool_calls      JSONB DEFAULT NULL,           -- OpenAI tool_calls format
    tool_call_id    TEXT DEFAULT NULL,            -- For tool response messages

    -- Tracing (Links to Phoenix)
    trace_id        TEXT,                         -- Phoenix trace ID
    span_id         TEXT,                         -- Phoenix span ID

    -- Cost Tracking
    model           TEXT,
    prompt_tokens   INTEGER,
    completion_tokens INTEGER,
    total_tokens    INTEGER,
    cost_usd        DECIMAL(10, 6),               -- Estimated cost
    latency_ms      INTEGER,                      -- Response time

    -- Timestamps
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_chat_messages_session
    ON chat_messages(session_id);

CREATE INDEX IF NOT EXISTS idx_chat_messages_trace
    ON chat_messages(trace_id);

-- -----------------------------------------------------------------------------
-- STEP 5: Job Queue Status (Track Celery Jobs)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS job_status (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

    -- Celery Job Info
    celery_task_id  TEXT UNIQUE NOT NULL,         -- Celery's task ID
    task_name       TEXT NOT NULL,                -- e.g., 'ingest_document'

    -- Status Tracking
    status          TEXT DEFAULT 'pending'
                    CHECK (status IN ('pending', 'running', 'success', 'failed', 'retrying')),
    progress        INTEGER DEFAULT 0,            -- 0-100 percentage

    -- Input/Output
    input_data      JSONB DEFAULT '{}',           -- Task arguments
    result_data     JSONB DEFAULT NULL,           -- Task result
    error_message   TEXT DEFAULT NULL,            -- Error details if failed

    -- Timestamps
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    started_at      TIMESTAMPTZ,
    completed_at    TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_job_status_celery
    ON job_status(celery_task_id);

CREATE INDEX IF NOT EXISTS idx_job_status_status
    ON job_status(status);

-- -----------------------------------------------------------------------------
-- STEP 6: Prompt Templates (Prompt Management)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS prompt_templates (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

    -- Identification
    name            TEXT UNIQUE NOT NULL,         -- e.g., 'customer-support-v1'
    version         INTEGER DEFAULT 1,

    -- Content
    system_prompt   TEXT NOT NULL,
    user_template   TEXT,                         -- Template with {{variables}}

    -- Configuration
    model           TEXT DEFAULT 'gpt-4o',
    temperature     DECIMAL(3, 2) DEFAULT 0.7,
    max_tokens      INTEGER DEFAULT 1024,

    -- Metadata
    tags            TEXT[] DEFAULT '{}',
    is_active       BOOLEAN DEFAULT true,

    -- Timestamps
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- -----------------------------------------------------------------------------
-- STEP 7: Helper Functions
-- -----------------------------------------------------------------------------

-- Function: Search knowledge base by similarity
CREATE OR REPLACE FUNCTION search_knowledge(
    query_embedding vector(1536),
    match_threshold FLOAT DEFAULT 0.7,
    match_count INT DEFAULT 5
)
RETURNS TABLE (
    id UUID,
    content_markdown TEXT,
    metadata JSONB,
    similarity FLOAT
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT
        kb.id,
        kb.content_markdown,
        kb.metadata,
        1 - (kb.embedding <=> query_embedding) AS similarity
    FROM knowledge_base kb
    WHERE 1 - (kb.embedding <=> query_embedding) > match_threshold
    ORDER BY kb.embedding <=> query_embedding
    LIMIT match_count;
END;
$$;

-- Function: Get recent chat history
CREATE OR REPLACE FUNCTION get_chat_history(
    p_session_id UUID,
    p_limit INT DEFAULT 20
)
RETURNS TABLE (
    role TEXT,
    content TEXT,
    created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT cm.role, cm.content, cm.created_at
    FROM chat_messages cm
    WHERE cm.session_id = p_session_id
    ORDER BY cm.created_at DESC
    LIMIT p_limit;
END;
$$;

-- -----------------------------------------------------------------------------
-- STEP 8: Triggers for Updated Timestamps
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_knowledge_base_updated
    BEFORE UPDATE ON knowledge_base
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trg_chat_sessions_updated
    BEFORE UPDATE ON chat_sessions
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trg_prompt_templates_updated
    BEFORE UPDATE ON prompt_templates
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();