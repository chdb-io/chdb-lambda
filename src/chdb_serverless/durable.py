"""L2 store: a Durable Analytical Object as the engine.

The whole difference between the stateless L1 recipe and a durable per-user
analyst is this file being chosen by the store seam. The same app, image, and
deploy scripts run unchanged; `CHDB_STORE=durable:<url>?id=<who>` points the
engine at a `chdb.durable` object on object storage you own, so the analyst's
tables and history survive the instance and are portable across clouds.

Spec (the part after `durable:`):
    durable:s3://bucket/prefix?id=user-123
    durable:local:/var/data?id=user-123
Object id also readable from CHDB_DURABLE_ID; writer identity from
CHDB_DURABLE_OWNER (defaults to the hostname); database from CHDB_DURABLE_DB.

Reads go straight to the object; writes are logged to its WAL and flushed
immediately, so a committed write survives an instance dying mid-session.
chDB is single-writer per process, so this store IS the process's one engine.
"""
from __future__ import annotations

import os
import socket
import threading
import re
from urllib.parse import parse_qs

from .store import Store

_WRITE_KEYWORDS = {
    "INSERT", "CREATE", "ALTER", "DROP", "RENAME", "TRUNCATE",
    "DELETE", "UPDATE", "OPTIMIZE", "ATTACH", "DETACH", "BACKUP", "RESTORE",
}

# Leading SQL comment — a `-- line` comment or a `/* block */` comment. Stripped
# before reading the first keyword so `/* migration */ CREATE TABLE ...` and
# `-- note\nINSERT ...` are still classified as writes (and routed to the WAL),
# not misread as reads because the comment was the "first token".
_LEADING_COMMENT = re.compile(r"^\s*(?:--[^\n]*(?:\n|$)|/\*.*?\*/)", re.DOTALL)


def _is_write(sql: str) -> bool:
    s = sql.strip()
    while True:
        m = _LEADING_COMMENT.match(s)
        if not m:
            break
        s = s[m.end():].lstrip()
    if not s:
        return False
    return s.split(None, 1)[0].upper() in _WRITE_KEYWORDS


class DurableStore(Store):
    def __init__(self, target: str) -> None:
        from chdb import durable as cd

        url, _, query = target.partition("?")
        params = parse_qs(query)
        oid = params.get("id", [os.getenv("CHDB_DURABLE_ID", "default")])[0]
        owner = os.getenv("CHDB_DURABLE_OWNER") or socket.gethostname()
        db = os.getenv("CHDB_DURABLE_DB", "mem")

        self._ns = cd.Namespace(url, owner=owner, db=db)
        self._obj = self._ns.open(oid)
        self._lock = threading.Lock()
        self.db = db
        self.oid = oid

    def query(self, sql: str, fmt: str = "JSONCompact") -> str:
        with self._lock:
            if _is_write(sql):
                self._obj.execute(sql)
                self._obj.flush()  # RPO≈0: a committed write is durable at return
                return ""
            return self._obj.query(sql, fmt).data()

    def checkpoint(self) -> None:
        """Fold the WAL into a fresh base (call periodically / before shutdown)."""
        with self._lock:
            self._obj.checkpoint()

    def close(self) -> None:
        with self._lock:
            self._obj.close()
