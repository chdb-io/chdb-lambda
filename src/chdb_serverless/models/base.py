"""The ModelBackend contract every provider adapter implements.

A backend owns the tool-use loop in its provider's native shape — including
the message format it appends to `history` — so no fake cross-provider
normalization is needed. The analyst core hands it a neutral system prompt
and tool spec; the backend translates, loops, runs SQL via `execute_sql`,
and returns the final answer text.
"""
from __future__ import annotations

from typing import Callable, Protocol


def clip(out: str, limit: int = 8000) -> str:
    """Bound a tool payload and mark when it was clipped, so the model sees
    truncation rather than treating malformed/partial JSON as complete."""
    return out if len(out) <= limit else out[:limit] + "\n…[truncated]"


class ModelBackend(Protocol):
    def run_analyst(
        self,
        system: str,
        tool: dict,
        question: str,
        history: list,
        execute_sql: Callable[[str], str],
        max_rounds: int,
    ) -> str:
        ...
