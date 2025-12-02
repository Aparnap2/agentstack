"""
==============================================================================
AgentStack Worker - Phoenix Tracing Setup
==============================================================================
"""
import os
from phoenix.otel import register
from openinference.instrumentation.openai import OpenAIInstrumentor

def setup_tracing():
    """
    Configure OpenTelemetry tracing to send spans to Arize Phoenix.
    This function should be called once when the worker starts.
    """
    phoenix_endpoint = os.getenv(
        'PHOENIX_COLLECTOR_HTTP_ENDPOINT',
        'http://localhost:6006/v1/traces'
    )
    project_name = os.getenv('PHOENIX_PROJECT_NAME', 'agentstack-worker')

    # Register the tracer provider with Phoenix
    tracer_provider = register(
        project_name=project_name,
        endpoint=phoenix_endpoint,
        batch=True,  # Batch spans for efficiency
        set_global_tracer_provider=True,
    )

    # Auto-instrument OpenAI SDK
    OpenAIInstrumentor().instrument(tracer_provider=tracer_provider)

    return tracer_provider


def get_tracer(name: str = "agentstack.worker"):
    """Get a tracer instance for manual instrumentation."""
    from opentelemetry import trace
    return trace.get_tracer(name)