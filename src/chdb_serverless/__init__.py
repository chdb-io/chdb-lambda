"""chdb-serverless — the base for running a chDB analyst on serverless.

One app, one image, every cloud; and one store seam that carries it from a
stateless function (L1) to a durable per-user analyst (L2) to an analytical
memory layer (L3). Deploy scripts live under deploy/; the story lives in the
chDB cookbook.
"""
from .store import Store, LocalStore, open_store

__all__ = ["analyst_app", "open_store", "Store", "LocalStore"]
__version__ = "0.1.0"


def analyst_app():
    """Return the FastAPI app (imported lazily so `open_store` and packaging
    metadata don't pull in FastAPI/uvicorn unless you actually serve)."""
    from .server import app

    return app
