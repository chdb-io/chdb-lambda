"""The store seam: the one place the tier (L1/L2/L3) is chosen.

Everything else in this package — the agent, the HTTP app, the image, the
deploy scripts — is identical across tiers. What changes from a stateless
serverless function (L1) to a durable per-user analyst (L2) to an analytical
memory layer (L3) is only what `open_store()` returns.

`open_store()` reads the CHDB_STORE spec (env var or argument):

    local:/tmp/chdb-data      L1 — an in-process chDB session on local disk,
                                   ephemeral with the instance (this package).
    durable:s3://bucket/obj   L2 — a chdb.durable object on S3-compatible
                                   storage, portable across clouds.
                                   Needs: pip install chdb-serverless[durable]
    memory:s3://bucket/obj    L3 — an analytical agent-memory layer on top
                                   of the durable object.
                                   Needs: pip install chdb-serverless[memory]

L1 is implemented here. L2/L3 are declared contracts, wired to the extras
that will implement them (chdb.durable / chdb-memory) — importing them
without the extra installed raises a clear, actionable error rather than a
mystery ImportError.
"""
from __future__ import annotations

import os
import threading

from .errors import MissingDependency


def open_store(spec: str | None = None) -> "Store":
    spec = spec or os.getenv(
        "CHDB_STORE", f"local:{os.getenv('CHDB_DATA_PATH', '/tmp/chdb-data')}"
    )
    scheme, _, target = spec.partition(":")
    if scheme == "local":
        return LocalStore(target)
    if scheme == "durable":
        try:
            from chdb_serverless.durable import DurableStore
        except ImportError as exc:  # extra not installed
            raise MissingDependency(
                "durable: stores need the durable extra — "
                "pip install chdb-serverless[durable]"
            ) from exc
        return DurableStore(target)
    if scheme == "memory":
        try:
            from chdb_serverless.memory import MemoryStore
        except ImportError as exc:
            raise MissingDependency(
                "memory: stores need the memory extra — "
                "pip install chdb-serverless[memory]"
            ) from exc
        return MemoryStore(target)
    raise ValueError(f"unknown store scheme {scheme!r} in {spec!r}")


class Store:
    """Minimal interface every tier implements: run one SQL statement, return
    its result as a string in the requested ClickHouse output format."""

    def query(self, sql: str, fmt: str = "JSONCompact") -> str:
        raise NotImplementedError


class LocalStore(Store):
    """L1: one in-process chDB session against a local path. Single-writer,
    so engine access is serialized — the same discipline the recipes use."""

    def __init__(self, path: str) -> None:
        from chdb import session as chdb_session

        self._session = chdb_session.Session(path)
        self._lock = threading.Lock()

    def query(self, sql: str, fmt: str = "JSONCompact") -> str:
        with self._lock:
            return self._session.query(sql, fmt).data()
