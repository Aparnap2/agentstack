"""
==============================================================================
AgentStack Worker - Embedding Generation
==============================================================================
"""
import os
from openai import OpenAI
from tenacity import retry, stop_after_attempt, wait_exponential

# =============================================================================
# OPENAI CLIENT (via LiteLLM Gateway)
# =============================================================================

# Use LiteLLM Gateway as the base URL
client = OpenAI(
    base_url=os.getenv('LITELLM_BASE_URL', 'http://localhost:4000'),
    api_key=os.getenv('OPENAI_API_KEY', 'fake-key'),  # LiteLLM handles the real key
)

# =============================================================================
# EMBEDDING FUNCTIONS
# =============================================================================

@retry(
    stop=stop_after_attempt(3),
    wait=wait_exponential(multiplier=1, min=2, max=10)
)
def generate_embedding(
    text: str,
    model: str = "text-embedding-3-small"
) -> list[float]:
    """
    Generate an embedding vector for the given text.
    Uses LiteLLM Gateway which routes to the configured model.

    Args:
        text: The text to embed
        model: The embedding model to use

    Returns:
        A list of floats representing the embedding vector
    """
    # Truncate text if too long (OpenAI limit is ~8191 tokens)
    max_chars = 30000  # Approximate safe limit
    if len(text) > max_chars:
        text = text[:max_chars]

    response = client.embeddings.create(
        input=text,
        model=model,
    )

    return response.data[0].embedding


def generate_embeddings_batch(
    texts: list[str],
    model: str = "text-embedding-3-small",
    batch_size: int = 100
) -> list[list[float]]:
    """
    Generate embeddings for multiple texts in batches.

    Args:
        texts: List of texts to embed
        model: The embedding model to use
        batch_size: Number of texts per API call

    Returns:
        List of embedding vectors
    """
    embeddings = []

    for i in range(0, len(texts), batch_size):
        batch = texts[i:i + batch_size]

        # Truncate each text
        batch = [t[:30000] for t in batch]

        response = client.embeddings.create(
            input=batch,
            model=model,
        )

        # Extract embeddings in order
        batch_embeddings = [d.embedding for d in response.data]
        embeddings.extend(batch_embeddings)

    return embeddings