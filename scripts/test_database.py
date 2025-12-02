#!/usr/bin/env python3
"""
==============================================================================
AgentStack OSS - Database Integration Tests
==============================================================================
"""
import os
import sys
import json
from sqlalchemy import create_engine, text
from pgvector.sqlalchemy import Vector

def test_database_connection():
    """Test basic database connection and schema."""
    print("🧪 Testing database connection...")

    # Use environment variables or defaults
    db_url = os.getenv('DATABASE_URL', 'postgresql://postgres:password@localhost:5432/agentstack')

    try:
        engine = create_engine(db_url)
        with engine.connect() as conn:
            # Test basic connection
            result = conn.execute(text("SELECT version()"))
            version = result.scalar()
            print(f"✅ Connected to PostgreSQL: {version[:50]}...")

            # Test extensions
            result = conn.execute(text("SELECT extname FROM pg_extension WHERE extname IN ('vector', 'uuid-ossp', 'pg_trgm')"))
            extensions = [row[0] for row in result]
            print(f"✅ Extensions loaded: {', '.join(extensions)}")

            # Test tables
            result = conn.execute(text("SELECT tablename FROM pg_tables WHERE schemaname = 'public'"))
            tables = [row[0] for row in result]
            print(f"✅ Tables created: {', '.join(tables)}")

            return True

    except Exception as e:
        print(f"❌ Database connection failed: {e}")
        return False

def test_vector_functionality():
    """Test vector operations and similarity search."""
    print("\n🧪 Testing vector functionality...")

    db_url = os.getenv('DATABASE_URL', 'postgresql://postgres:password@localhost:5432/agentstack')

    try:
        engine = create_engine(db_url)
        with engine.connect() as conn:
            # Create a test vector
            test_vector = [0.1] * 1536  # Simple 1536-dim vector

            # Insert test document
            result = conn.execute(text("""
                INSERT INTO knowledge_base
                (source_url, source_type, filename, content_markdown, embedding, metadata, char_count)
                VALUES (:source_url, :source_type, :filename, :content_markdown, :embedding, :metadata, :char_count)
                RETURNING id
            """), {
                "source_url": "test://ai-concepts",
                "source_type": "text",
                "filename": "ai_concepts.txt",
                "content_markdown": "Machine learning is a subset of artificial intelligence that focuses on algorithms that can learn from data.",
                "embedding": str(test_vector),
                "metadata": json.dumps({"category": "ML", "level": "intermediate"}),
                "char_count": 142
            })

            doc_id = result.scalar()
            print(f"✅ Inserted test document with ID: {doc_id}")

            # Test similarity search
            query_vector = [0.1] * 1536  # Same vector for perfect match
            result = conn.execute(text("""
                SELECT id, filename, 1 - (embedding <=> :query_vector) as similarity
                FROM knowledge_base
                WHERE 1 - (embedding <=> :query_vector) > 0.5
                ORDER BY embedding <=> :query_vector
                LIMIT 5
            """), {"query_vector": str(query_vector)})

            results = result.fetchall()
            print(f"✅ Found {len(results)} similar documents")

            for row in results:
                print(f"   - Document {row[0]} ({row[1]}): similarity = {row[2]:.4f}")

            return True

    except Exception as e:
        print(f"❌ Vector functionality test failed: {e}")
        return False

def test_helper_functions():
    """Test our helper functions."""
    print("\n🧪 Testing helper functions...")

    db_url = os.getenv('DATABASE_URL', 'postgresql://postgres:password@localhost:5432/agentstack')

    try:
        engine = create_engine(db_url)
        with engine.connect() as conn:
            # Test search_knowledge function
            query_vector = [0.1] * 1536
            result = conn.execute(text("""
                SELECT * FROM search_knowledge(:query_embedding::vector, 0.5, 5)
            """), {"query_embedding": str(query_vector)})

            results = result.fetchall()
            print(f"✅ search_knowledge function returned {len(results)} results")

            # Test get_chat_history function (should be empty)
            result = conn.execute(text("""
                SELECT * FROM get_chat_history('00000000-0000-0000-0000-000000000000', 10)
            """))

            results = result.fetchall()
            print(f"✅ get_chat_history function returned {len(results)} results (expected empty)")

            return True

    except Exception as e:
        print(f"❌ Helper functions test failed: {e}")
        return False

def main():
    """Run all database tests."""
    print("🚀 AgentStack OSS - Database Integration Tests")
    print("=" * 50)

    # Check environment
    if not os.getenv('DATABASE_URL'):
        print("⚠️  DATABASE_URL not set, using default: postgresql://postgres:password@localhost:5432/agentstack")

    tests = [
        test_database_connection,
        test_vector_functionality,
        test_helper_functions,
    ]

    passed = 0
    total = len(tests)

    for test in tests:
        if test():
            passed += 1

    print("\n" + "=" * 50)
    print(f"📊 Test Results: {passed}/{total} tests passed")

    if passed == total:
        print("🎉 All tests passed! Database layer is working correctly.")
        return 0
    else:
        print("💥 Some tests failed. Check the error messages above.")
        return 1

if __name__ == "__main__":
    sys.exit(main())