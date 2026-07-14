"""The analyst: a system prompt, one tool, and a provider-neutral turn.

The LLM is a plug — `ask()` delegates the tool-use loop to a ModelBackend
(see models/), so the analyst is not anchored to any one provider. Anthropic
is the reference backend; an OpenAI-compatible backend covers OpenAI, Gemini
(compat endpoint), and local servers (Ollama/vLLM) via a base_url. Pick one
with the CHDB_MODEL env var, e.g. `anthropic:claude-opus-4-8` or
`openai:gpt-4.1` or `openai:llama3@http://localhost:11434/v1`.
"""
from __future__ import annotations

import os
import sys

from .models import open_model

MAX_TOOL_ROUNDS = 12  # cap tool-use rounds so a runaway question can't burn budget

SYSTEM = """You are a data analyst with an embedded ClickHouse engine (chDB) in your process.
demo.hits holds web analytics events (the ClickBench dataset): one row per page hit, with
EventDate, CounterID (site id), UserID, URL, Referer, SearchPhrase, RegionID, OS, IsMobile,
ResolutionWidth and ~100 more columns. Answer questions by writing ClickHouse SQL: prefer
aggregates, LIMIT any raw-row output. You can also reach live external data in the same SQL,
e.g. s3('https://clickhouse-public-datasets.s3.amazonaws.com/hits_compatible/athena_partitioned/hits_1.parquet', NOSIGN).
To remember expensive results for later questions, materialize them:
CREATE TABLE demo.<name> ENGINE = MergeTree ORDER BY tuple() AS SELECT ..."""

# Provider-neutral tool spec; each ModelBackend maps it to its own format.
TOOL = {
    "name": "execute_sql",
    "description": "Run one ClickHouse SQL statement on the in-process engine; returns JSON.",
    "schema": {
        "type": "object",
        "properties": {"sql": {"type": "string", "description": "A single SQL statement"}},
        "required": ["sql"],
    },
}


def ask(question: str, history: list, execute_sql, model=None) -> str:
    """One analyst turn. `history` is mutated in place (its shape is owned by
    the backend); `execute_sql` runs SQL -> str; `model` defaults to
    open_model() (CHDB_MODEL env)."""
    model = model or open_model()
    return model.run_analyst(SYSTEM, TOOL, question, history, execute_sql, MAX_TOOL_ROUNDS)


if __name__ == "__main__":
    from .store import open_store

    store = open_store()
    history: list = []
    print("chDB analyst ready — ask about demo.hits (Ctrl-D to exit)")
    for line in sys.stdin:
        if line.strip():
            print(ask(line.strip(), history, lambda sql: store.query(sql) or "{}"))
