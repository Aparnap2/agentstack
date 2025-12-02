"""
==============================================================================
AgentStack Worker - Document Parsing with Docling
==============================================================================
"""
import os
import tempfile
from pathlib import Path
from urllib.parse import urlparse
import httpx
from docling.document_converter import DocumentConverter, PdfFormatOption
from docling.datamodel.pipeline_options import PdfPipelineOptions
from docling.datamodel.base_models import InputFormat

# =============================================================================
# DOCLING CONFIGURATION
# =============================================================================

# Configure Docling options
pipeline_options = PdfPipelineOptions()
pipeline_options.do_ocr = True  # Enable OCR for scanned PDFs
pipeline_options.do_table_structure = True  # Extract table structure

# Create converter instance (reuse for efficiency)
converter = DocumentConverter(
    allowed_formats=[
        InputFormat.PDF,
        InputFormat.DOCX,
        InputFormat.PPTX,
        InputFormat.HTML,
        InputFormat.IMAGE,
        InputFormat.MD,
    ],
    format_options={
        InputFormat.PDF: PdfFormatOption(pipeline_options=pipeline_options)
    }
)


# =============================================================================
# PARSING FUNCTIONS
# =============================================================================

def download_file(url: str) -> tuple[str, str]:
    """
    Download a file from URL to a temporary location.
    Returns tuple of (local_path, detected_filename).
    """
    # Parse filename from URL
    parsed = urlparse(url)
    filename = Path(parsed.path).name or "document"

    # Download with httpx
    with httpx.Client(timeout=120.0) as client:
        response = client.get(url, follow_redirects=True)
        response.raise_for_status()

        # Detect extension from content-type if not in filename
        if '.' not in filename:
            content_type = response.headers.get('content-type', '')
            ext_map = {
                'application/pdf': '.pdf',
                'application/vnd.openxmlformats-officedocument.wordprocessingml.document': '.docx',
                'text/html': '.html',
            }
            ext = ext_map.get(content_type.split(';')[0], '.pdf')
            filename = filename + ext

        # Save to temp file
        suffix = Path(filename).suffix
        with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
            tmp.write(response.content)
            return tmp.name, filename


def parse_document(source: str) -> dict:
    """
    Parse a document from URL or local path.

    Args:
        source: URL or local file path

    Returns:
        Dictionary containing:
        - markdown: Cleaned markdown content
        - filename: Original filename
        - source_type: File type (pdf, docx, etc.)
        - metadata: Extracted metadata
    """
    local_path = source
    filename = Path(source).name
    cleanup_file = False

    # Download if URL
    if source.startswith(('http://', 'https://')):
        local_path, filename = download_file(source)
        cleanup_file = True

    try:
        # Convert document
        result = converter.convert(local_path)

        # Export to markdown
        markdown_content = result.document.export_to_markdown()

        # Determine source type
        suffix = Path(filename).suffix.lower().lstrip('.')
        source_type = suffix if suffix else 'unknown'

        # Extract metadata
        metadata = {
            "title": getattr(result.document, 'title', None),
            "num_pages": getattr(result.document, 'num_pages', None),
            "tables_count": len(result.document.tables) if hasattr(result.document, 'tables') else 0,
        }

        return {
            "markdown": markdown_content,
            "filename": filename,
            "source_type": source_type,
            "metadata": metadata,
        }

    finally:
        # Cleanup temp file if downloaded
        if cleanup_file and os.path.exists(local_path):
            os.unlink(local_path)


def chunk_text(
    text: str,
    chunk_size: int = 1000,
    chunk_overlap: int = 200
) -> list[str]:
    """
    Split text into overlapping chunks for embedding.

    Args:
        text: The text to chunk
        chunk_size: Maximum characters per chunk
        chunk_overlap: Number of overlapping characters between chunks

    Returns:
        List of text chunks
    """
    if len(text) <= chunk_size:
        return [text]

    chunks = []
    start = 0

    while start < len(text):
        end = start + chunk_size

        # Try to break at sentence boundary
        if end < len(text):
            # Look for sentence end within last 20% of chunk
            search_start = end - int(chunk_size * 0.2)
            for sep in ['. ', '.\n', '! ', '? ', '\n\n']:
                idx = text.rfind(sep, search_start, end)
                if idx != -1:
                    end = idx + len(sep)
                    break

        chunks.append(text[start:end].strip())
        start = end - chunk_overlap

    return chunks