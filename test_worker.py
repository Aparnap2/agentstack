#!/usr/bin/env python3
"""
==============================================================================
AgentStack OSS - Worker Integration Tests
==============================================================================
"""
import os
import sys
from unittest.mock import Mock, patch
import tempfile
from pathlib import Path

# Add src to path
sys.path.insert(0, str(Path(__file__).parent / "src"))

# Import the modules correctly
try:
    from agentstack_worker.database import insert_document, search_similar_documents
    from agentstack_worker.embeddings import generate_embedding
    from agentstack_worker.docling_parser import parse_document, chunk_text
    print("✅ Worker modules imported successfully")
except ImportError as e:
    print(f"❌ Import error: {e}")
    print("This is expected since we haven't fully implemented the modules yet")
    print("Proceeding with mock tests...")

def test_embedding_generation():
    """Test embedding generation without external dependencies."""
    print("🧪 Testing embedding generation...")

    # Mock the OpenAI client
    with patch('agentstack_worker.embeddings.client') as mock_client:
        # Create a mock response
        mock_response = Mock()
        mock_response.data = [Mock(embedding=[0.1] * 1536)]
        mock_client.embeddings.create.return_value = mock_response

        from agentstack_worker.embeddings import generate_embedding
        result = generate_embedding("test text")

        assert len(result) == 1536
        print("✅ Embedding generation test passed")
        return True

def test_document_parsing():
    """Test document parsing functionality."""
    print("\n🧪 Testing document parsing...")

    # Create a test document
    test_content = "# Test Document\n\nThis is a test document with some content."

    # Mock the docling converter
    with patch('agentstack_worker.docling_parser.converter') as mock_converter:
        mock_result = Mock()
        mock_result.document.export_to_markdown.return_value = test_content
        mock_converter.convert.return_value = mock_result

        from agentstack_worker.docling_parser import parse_document
        result = parse_document("test://local")

        assert result["markdown"] == test_content
        print("✅ Document parsing test passed")
        return True

def test_database_operations():
    """Test database operations with mocked connection."""
    print("\n🧪 Testing database operations...")

    # Mock the database session
    with patch('agentstack_worker.database.get_db_session') as mock_session:
        mock_session = Mock()
        mock_result = Mock()
        mock_result.scalar.return_value = "test-doc-id"
        mock_session.execute.return_value = mock_result
        mock_session.__enter__ = Mock(return_value=mock_session)
        mock_session.__exit__ = Mock(return_value=None)
        mock_session.__enter__.return_value = mock_session

        from agentstack_worker.database import insert_document
        result = insert_document(
            source_url="test://doc",
            source_type="text",
            filename="test.txt",
            content_markdown="Test content",
            embedding=[0.1] * 1536,
            metadata={"test": True}
        )

        assert result == "test-doc-id"
        print("✅ Database operations test passed")
        return True

def test_text_chunking():
    """Test text chunking functionality."""
    print("\n🧪 Testing text chunking...")

    from agentstack_worker.docling_parser import chunk_text

    # Test with simple text
    test_text = "This is a test. This is another sentence. This is a third sentence to test chunking."
    chunks = chunk_text(test_text, chunk_size=50, chunk_overlap=10)

    assert len(chunks) >= 2  # Should create at least 2 chunks
    assert all(len(chunk) <= 50 + 20 for chunk in chunks)  # Allow some overlap
    print(f"✅ Text chunking test passed - created {len(chunks)} chunks")
    return True

def test_similarity_search():
    """Test vector similarity search."""
    print("\n🧪 Testing vector similarity search...")

    # Mock database query results
    mock_results = [
        {"id": "doc1", "content_markdown": "AI and ML content", "similarity": 0.95},
        {"id": "doc2", "content_markdown": "Another document", "similarity": 0.85}
    ]

    with patch('agentstack_worker.database.get_db_session') as mock_session:
        mock_session.return_value.__enter__.return_value.execute.return_value.fetchall.return_value = mock_results

        from agentstack_worker.database import search_similar_documents
        result = search_similar_documents([0.1] * 1536, limit=5, threshold=0.7)

        assert len(result) == 2
        assert result[0]["similarity"] == 0.95
        print("✅ Vector similarity search test passed")
        return True

def main():
    """Run all worker tests."""
    print("🚀 AgentStack OSS - Worker Unit Tests")
    print("=" * 50)

    # Set up test environment
    os.environ.setdefault('DATABASE_URL', 'postgresql://postgres:password@localhost:5432/agentstack')

    tests = [
        test_embedding_generation,
        test_document_parsing,
        test_database_operations,
        test_text_chunking,
        test_similarity_search
    ]

    passed = 0
    total = len(tests)

    for test in tests:
        try:
            if test():
                passed += 1
        except Exception as e:
            print(f"❌ Test failed: {e}")

    print("\n" + "=" * 50)
    print(f"📊 Test Results: {passed}/{total} tests passed")

    if passed == total:
        print("🎉 All worker tests passed! Core functionality verified.")
        return 0
    else:
        print("💥 Some tests failed. Check error messages above.")
        return 1

if __name__ == "__main__":
    sys.exit(main())