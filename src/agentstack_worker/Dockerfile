# =============================================================================
# AgentStack Worker - Dockerfile
# =============================================================================
FROM python:3.11-slim

# Set working directory
WORKDIR /app

# Install system dependencies for Docling and psycopg2
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libpq-dev \
    libgl1-mesa-glx \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender-dev \
    poppler-utils \
    tesseract-ocr \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements first (for caching)
COPY requirements.txt .

# Install Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Pre-download Docling models (improves startup time)
RUN python -c "from docling.document_converter import DocumentConverter; DocumentConverter()"

# Copy application code
COPY . .

# Set Python path
ENV PYTHONPATH=/app
ENV PYTHONUNBUFFERED=1

# Default command (overridden in docker-compose)
CMD ["celery", "-A", "celery_app", "worker", "--loglevel=info"]