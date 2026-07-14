"""Anthropic reference backend — the tool-use loop the recipes shipped."""
from __future__ import annotations

from typing import Callable

import anthropic

from .base import clip


class AnthropicModel:
    def __init__(self, model: str) -> None:
        self.model = model
        self.client = anthropic.Anthropic()  # reads ANTHROPIC_API_KEY at request time

    def run_analyst(
        self,
        system: str,
        tool: dict,
        question: str,
        history: list,
        execute_sql: Callable[[str], str],
        max_rounds: int,
    ) -> str:
        tools = [{
            "name": tool["name"],
            "description": tool["description"],
            "input_schema": tool["schema"],
        }]
        history.append({"role": "user", "content": question})
        for _ in range(max_rounds):
            response = self.client.messages.create(
                model=self.model, max_tokens=16000, system=system, tools=tools, messages=history)
            history.append({"role": "assistant", "content": response.content})
            if response.stop_reason != "tool_use":
                return "".join(b.text for b in response.content if b.type == "text")
            results = []
            for block in response.content:
                if block.type == "tool_use":
                    try:
                        results.append({"type": "tool_result", "tool_use_id": block.id,
                                        "content": clip(execute_sql(block.input["sql"]))})
                    except Exception as exc:
                        results.append({"type": "tool_result", "tool_use_id": block.id,
                                        "content": str(exc)[:2000], "is_error": True})
            history.append({"role": "user", "content": results})
        return "Stopped after the maximum number of tool-use rounds without a final answer."
