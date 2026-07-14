"""The HTTP app: /health /query /ask over a chDB store.

Store-agnostic by construction — it talks to whatever `open_store()` returns,
so the same server runs L1 (local, this package), L2 (durable), or L3
(memory) with no code change, only a different CHDB_STORE and extra. That is
the base's whole point: one app, every tier.
"""
from __future__ import annotations

import json
import logging
import os
import sys
import threading
import time
import uuid

import uvicorn
from fastapi import FastAPI
from fastapi.responses import JSONResponse, PlainTextResponse
from pydantic import BaseModel

import chdb

from . import agent
from .models import missing_credential
from .store import open_store

logging.basicConfig(
    level=logging.INFO,
    stream=sys.stdout,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("chdb-analyst")

APP_PORT = int(os.getenv("PORT", "8080"))  # the platform injects PORT

# The single point of tier variation. L1 returns a local in-process session;
# L2/L3 return durable/memory-backed stores — the app below never knows which.
_store = open_store()
_ask_lock = threading.Lock()  # serializes whole analyst turns against _history
_instance_id = uuid.uuid4().hex[:8]
_started_at = time.monotonic()

# formats that are a single JSON document we can embed in the response.
# JSONObjectEachRow is newline-delimited (one object per line), NOT one
# document, so it's returned as text like the other row formats.
_JSON_FORMATS = {"JSON", "JSONCompact", "JSONColumns"}

app = FastAPI(title="chDB serverless analyst")


class QueryRequest(BaseModel):
    sql: str
    format: str = "JSONCompact"  # any ClickHouse output format


class AskRequest(BaseModel):
    question: str


@app.get("/health")
def health() -> dict:
    rows = _store.query("SELECT count() FROM demo.hits", "TabSeparated").strip()
    return {
        "status": "ok",
        "engine": f"chdb {chdb.__version__}",
        "baked_rows": int(rows),
        "instance": _instance_id,
        "uptime_s": round(time.monotonic() - _started_at, 1),
    }


# Conversation history is per-instance RAM: it survives between requests that
# land on the same warm instance and vanishes on scale-to-zero. Good enough
# for a demo conversation; durable memory is the L3 tier.
_history: list = []
_turns = 0  # provider-neutral: one completed /ask == one turn (len(_history) is backend-shaped)


@app.post("/ask")
def ask(req: AskRequest):
    missing = missing_credential()  # provider-aware: which key the chosen model needs
    if missing:
        return JSONResponse(
            {"error": f"{missing} not set; /ask is disabled (use /query for raw SQL)"},
            status_code=503,
        )
    started = time.perf_counter()
    # One conversation per instance: serialize whole turns so concurrent
    # requests can't interleave into the shared history, and roll a partial
    # turn back if the model call fails mid-flight.
    global _turns
    with _ask_lock:
        checkpoint = len(_history)
        try:
            answer = agent.ask(req.question, _history, lambda sql: _store.query(sql) or "{}")
        except Exception as exc:  # incl. MissingDependency (a plain Exception, not SystemExit)
            del _history[checkpoint:]
            return JSONResponse({"error": str(exc)}, status_code=502)
        _turns += 1
        turns = _turns  # capture inside the lock so we report our own count
    return {
        "answer": answer,
        "turns": turns,
        "instance": _instance_id,
        "elapsed_ms": round((time.perf_counter() - started) * 1000, 1),
    }


@app.post("/query")
def query(req: QueryRequest):
    started = time.perf_counter()
    try:
        raw = _store.query(req.sql, req.format)
    except Exception as exc:  # chDB raises RuntimeError with the CH error text
        return JSONResponse({"error": str(exc)}, status_code=400)
    elapsed_ms = round((time.perf_counter() - started) * 1000, 1)
    if req.format in _JSON_FORMATS:
        body = json.loads(raw) if raw else {}
        return {"elapsed_ms": elapsed_ms, "result": body}
    return PlainTextResponse(raw, headers={"X-Elapsed-Ms": str(elapsed_ms)})


def main() -> None:
    logger.info("app on :%d, instance %s", APP_PORT, _instance_id)
    uvicorn.run(app, host="0.0.0.0", port=APP_PORT, log_level="info")


if __name__ == "__main__":
    main()
