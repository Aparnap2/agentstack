"""
==============================================================================
AgentStack Worker - Celery Application
==============================================================================
"""
import os
from celery import Celery
from celery.signals import worker_init

# Import tracing setup (must be done early)
from .tracing import setup_tracing

# =============================================================================
# CELERY CONFIGURATION
# =============================================================================

# Create Celery app
app = Celery(
    'agentstack',
    broker=os.getenv('CELERY_BROKER_URL', 'redis://localhost:6379/0'),
    backend=os.getenv('CELERY_RESULT_BACKEND', 'redis://localhost:6379/1'),
    include=['.tasks']  # Import task modules
)

# Celery Configuration
app.conf.update(
    # Serialization
    task_serializer='json',
    accept_content=['json'],
    result_serializer='json',

    # Timezone
    timezone='UTC',
    enable_utc=True,

    # Task Settings
    task_track_started=True,
    task_time_limit=3600,  # 1 hour max per task
    task_soft_time_limit=3300,  # Warn at 55 minutes

    # Result Settings
    result_expires=86400,  # Results expire after 24 hours

    # Worker Settings
    worker_prefetch_multiplier=1,  # Process one task at a time per worker
    worker_max_tasks_per_child=100,  # Restart worker after 100 tasks (memory management)

    # Retry Settings
    task_acks_late=True,
    task_reject_on_worker_lost=True,
)

# =============================================================================
# WORKER INITIALIZATION
# =============================================================================

@worker_init.connect
def init_worker(**kwargs):
    """Initialize tracing when worker starts."""
    setup_tracing()
    print("✅ Worker initialized with Phoenix tracing")


if __name__ == '__main__':
    app.start()