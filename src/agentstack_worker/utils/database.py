"""
==============================================================================
AgentStack Worker - Database Utilities
==============================================================================
"""
import os
from contextlib import contextmanager
from sqlalchemy import create_engine, text
from sqlalchemy.orm import sessionmaker
from pgvector.sqlalchemy import Vector

# =============================================================================
# DATABASE CONNECTION
# =============================================================================

DATABASE_URL = os.getenv(
    'DATABASE_URL',
    'postgresql://postgres:password@localhost:5432/agentstack'
)

engine = create_engine(
    DATABASE_URL,
    pool_size=5,
    max_overflow=10,
    pool_pre_ping=True,  # Verify connections before use
    pool_recycle=3600,   # Recycle connections after 1 hour
)

SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

@contextmanager
def get_db_session():
    """Context manager for database sessions."""
    session = SessionLocal()
    try:
        yield session
        session.commit()
    except Exception:
        session.rollback()
        raise
    finally:
        session.close()


# =============================================================================
# DATABASE OPERATIONS
# =============================================================================

def insert_document(
    source_url: str,
    source_type: str,
    filename: str,
    content_markdown: str,
    embedding: list[float],
    metadata: dict = None
) -> str:
    """
    Insert a document with its embedding into the knowledge base.
    Returns the document ID.
    """
    with get_db_session() as session:
        result = session.execute(
            text("""
                INSERT INTO knowledge_base
                    (source_url, source_type, filename, content_markdown, embedding, metadata, char_count)
                VALUES
                    (:source_url, :source_type, :filename, :content_markdown, :embedding, :metadata, :char_count)
                RETURNING id
            """),
            {
                "source_url": source_url,
                "source_type": source_type,
                "filename": filename,
                "content_markdown": content_markdown,
                "embedding": str(embedding),  # pgvector accepts string format
                "metadata": metadata or {},
                "char_count": len(content_markdown),
            }
        )
        doc_id = result.scalar()
        return str(doc_id)


def search_similar_documents(
    query_embedding: list[float],
    limit: int = 5,
    threshold: float = 0.7
) -> list[dict]:
    """
    Search for similar documents using vector similarity.
    """
    with get_db_session() as session:
        result = session.execute(
            text("""
                SELECT
                    id,
                    filename,
                    content_markdown,
                    metadata,
                    1 - (embedding <=> :query_embedding) as similarity
                FROM knowledge_base
                WHERE 1 - (embedding <=> :query_embedding) > :threshold
                ORDER BY embedding <=> :query_embedding
                LIMIT :limit
            """),
            {
                "query_embedding": str(query_embedding),
                "threshold": threshold,
                "limit": limit,
            }
        )
        return [dict(row._mapping) for row in result]


def update_job_status(
    celery_task_id: str,
    status: str,
    progress: int = None,
    result_data: dict = None,
    error_message: str = None
):
    """Update job status in the database."""
    with get_db_session() as session:
        update_fields = ["status = :status"]
        params = {"celery_task_id": celery_task_id, "status": status}

        if progress is not None:
            update_fields.append("progress = :progress")
            params["progress"] = progress

        if result_data is not None:
            update_fields.append("result_data = :result_data")
            params["result_data"] = result_data

        if error_message is not None:
            update_fields.append("error_message = :error_message")
            params["error_message"] = error_message

        if status == "running":
            update_fields.append("started_at = NOW()")
        elif status in ("success", "failed"):
            update_fields.append("completed_at = NOW()")

        session.execute(
            text(f"""
                UPDATE job_status
                SET {', '.join(update_fields)}
                WHERE celery_task_id = :celery_task_id
            """),
            params
        )