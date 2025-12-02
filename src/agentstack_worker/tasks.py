"""
==============================================================================
AgentStack Worker - Celery Tasks
==============================================================================
"""
import os
import json
from celery import shared_task
from opentelemetry import trace

from .database import (
    insert_document,
    search_similar_documents,
    update_job_status,
    get_db_session,
)
from .embeddings import generate_embedding, generate_embeddings_batch
from .docling_parser import parse_document, chunk_text

# Get tracer for manual spans
tracer = trace.get_tracer("agentstack.tasks")


# =============================================================================
# DOCUMENT INGESTION TASK
# =============================================================================

@shared_task(
    bind=True,
    name='tasks.ingest_document',
    max_retries=3,
    default_retry_delay=60,
    autoretry_for=(Exception,),
    retry_backoff=True,
)
def ingest_document(self, source_url: str, metadata: dict = None):
    """
    Ingest a document from URL into knowledge base.

    This task:
    1. Downloads and parses document (Docling)
    2. Generates embedding (via LiteLLM Gateway)
    3. Stores in PostgreSQL with pgvector

    All steps are traced in Phoenix.

    Args:
        source_url: URL of document to ingest
        metadata: Optional metadata to attach

    Returns:
        Dictionary with document ID and stats
    """
    task_id = self.request.id

    # Track job in database
    with get_db_session() as session:
        from sqlalchemy import text
        session.execute(
            text("""
                INSERT INTO job_status (celery_task_id, task_name, status, input_data)
                VALUES (:task_id, 'ingest_document', 'running', :input_data)
                ON CONFLICT (celery_task_id) DO UPDATE SET status = 'running', started_at = NOW()
            """),
            {"task_id": task_id, "input_data": json.dumps({"source_url": source_url})}
        )

    try:
        with tracer.start_as_current_span("ingest_document") as span:
            span.set_attribute("source_url", source_url)

            # Step 1: Parse document with Docling
            with tracer.start_as_current_span("parse_document"):
                parsed = parse_document(source_url)
                markdown = parsed["markdown"]
                filename = parsed["filename"]
                source_type = parsed["source_type"]
                doc_metadata = parsed["metadata"]

            span.set_attribute("document.chars", len(markdown))
            span.set_attribute("document.type", source_type)

            # Step 2: Generate embedding
            with tracer.start_as_current_span("generate_embedding"):
                # Truncate for embedding (first 8000 chars for summary embedding)
                embed_text = markdown[:8000] if len(markdown) > 8000 else markdown
                embedding = generate_embedding(embed_text)

            span.set_attribute("embedding.dimensions", len(embedding))

            # Step 3: Store in database
            with tracer.start_as_current_span("store_document"):
                # Merge metadata
                final_metadata = {**(doc_metadata or {}), **(metadata or {})}

                doc_id = insert_document(
                    source_url=source_url,
                    source_type=source_type,
                    filename=filename,
                    content_markdown=markdown,
                    embedding=embedding,
                    metadata=final_metadata,
                )

            span.set_attribute("document.id", doc_id)

            # Update job status
            result = {
                "document_id": doc_id,
                "filename": filename,
                "source_type": source_type,
                "char_count": len(markdown),
                "status": "success",
            }

            update_job_status(
                celery_task_id=task_id,
                status="success",
                progress=100,
                result_data=result,
            )

            return result

    except Exception as e:
        update_job_status(
            celery_task_id=task_id,
            status="failed",
            error_message=str(e),
        )
        raise


# =============================================================================
# SEMANTIC SEARCH TASK
# =============================================================================

@shared_task(
    name='tasks.semantic_search',
    bind=True,
)
def semantic_search(self, query: str, limit: int = 5, threshold: float = 0.7):
    """
    Search knowledge base using semantic similarity.

    Args:
        query: The search query
        limit: Maximum number of results
        threshold: Minimum similarity score (0-1)

    Returns:
        List of matching documents with similarity scores
    """
    with tracer.start_as_current_span("semantic_search") as span:
        span.set_attribute("query", query)
        span.set_attribute("limit", limit)

        # Generate query embedding
        with tracer.start_as_current_span("query_embedding"):
            query_embedding = generate_embedding(query)

        # Search database
        with tracer.start_as_current_span("vector_search"):
            results = search_similar_documents(
                query_embedding=query_embedding,
                limit=limit,
                threshold=threshold,
            )

        span.set_attribute("results_count", len(results))

        return results


# =============================================================================
# BATCH INGESTION TASK
# =============================================================================

@shared_task(
    name='tasks.ingest_batch',
    bind=True,
)
def ingest_batch(self, source_urls: list[str], metadata: dict = None):
    """
    Ingest multiple documents in sequence.

    Args:
        source_urls: List of document URLs
        metadata: Shared metadata for all documents

    Returns:
        Summary of ingestion results
    """
    results = {
        "total": len(source_urls),
        "success": 0,
        "failed": 0,
        "documents": [],
    }

    for i, url in enumerate(source_urls):
        try:
            # Call ingest synchronously (already traced)
            result = ingest_document.apply(args=[url, metadata]).get(timeout=600)
            results["success"] += 1
            results["documents"].append(result)
        except Exception as e:
            results["failed"] += 1
            results["documents"].append({
                "source_url": url,
                "status": "failed",
                "error": str(e),
            })

        # Update progress
        self.update_state(
            state='PROGRESS',
            meta={'current': i + 1, 'total': len(source_urls)}
        )

    return results


# =============================================================================
# RAG QUERY TASK
# =============================================================================

@shared_task(
    name='tasks.rag_query',
    bind=True,
)
def rag_query(
    self,
    question: str,
    session_id: str = None,
    model: str = "gpt-4o",
    system_prompt: str = None,
):
    """
    Answer a question using RAG (Retrieval-Augmented Generation).

    Args:
        question: The user's question
        session_id: Optional chat session ID for history
        model: LLM model to use
        system_prompt: Custom system prompt

    Returns:
        Generated answer with sources
    """
    from openai import OpenAI

    client = OpenAI(
        base_url=os.getenv('LITELLM_BASE_URL', 'http://localhost:4000'),
        api_key=os.getenv('OPENAI_API_KEY', 'fake-key'),
    )

    with tracer.start_as_current_span("rag_query") as span:
        span.set_attribute("question", question)
        span.set_attribute("model", model)

        # Step 1: Retrieve relevant context
        with tracer.start_as_current_span("retrieve_context"):
            search_results = semantic_search.apply(
                args=[question, 5, 0.6]
            ).get(timeout=60)

            context_parts = []
            sources = []
            for doc in search_results:
                context_parts.append(doc["content_markdown"][:2000])
                sources.append({
                    "id": str(doc["id"]),
                    "filename": doc.get("filename"),
                    "similarity": doc.get("similarity"),
                })

            context = "\n\n---\n\n".join(context_parts)

        span.set_attribute("context.sources", len(sources))

        # Step 2: Generate answer
        with tracer.start_as_current_span("generate_answer"):
            default_system = """You are a helpful assistant that answers questions based on provided context.

Rules:
- Only answer based on the context provided
- If the context doesn't contain the answer, say "I don't have enough information to answer that question."
- Cite your sources by mentioning the document names
- Be concise but thorough"""

            messages = [
                {"role": "system", "content": system_prompt or default_system},
                {"role": "user", "content": f"""Context:
{context}

Question: {question}

Answer:"""}
            ]

            response = client.chat.completions.create(
                model=model,
                messages=messages,
                temperature=0.7,
                max_tokens=1024,
            )

            answer = response.choices[0].message.content

        span.set_attribute("answer.tokens", response.usage.total_tokens)

        return {
            "question": question,
            "answer": answer,
            "sources": sources,
            "model": model,
            "tokens": response.usage.total_tokens,
        }