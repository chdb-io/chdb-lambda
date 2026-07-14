"""OpenAI-compatible backend — covers OpenAI, and via base_url any
OpenAI-compatible server (Gemini's compat endpoint, Ollama, vLLM, …).

Note: written against the OpenAI chat-completions tool-calling shape;
validated for form, not yet run end-to-end in this repo (no key on the
build box). The Anthropic backend is the e2e-verified reference.
"""
from __future__ import annotations

import json
from typing import Callable

import openai

from .base import clip


class OpenAIModel:
    def __init__(self, model: str, base_url: str | None = None, api_key: str | None = None) -> None:
        self.model = model
        # The SDK errors at construction if it finds no key at all — but a
        # local OpenAI-compatible server (Ollama, vLLM, LM Studio) needs none.
        # Prefer an explicit key, then OPENAI_API_KEY, then a harmless
        # placeholder so no-auth base_url servers construct and work.
        import os
        self.client = openai.OpenAI(
            base_url=base_url,
            api_key=api_key or os.getenv("OPENAI_API_KEY") or "no-key-required",
        )

    def run_analyst(
        self,
        system: str,
        tool: dict,
        question: str,
        history: list,
        execute_sql: Callable[[str], str],
        max_rounds: int,
    ) -> str:
        tools = [{"type": "function", "function": {
            "name": tool["name"],
            "description": tool["description"],
            "parameters": tool["schema"],
        }}]
        if not history:
            history.append({"role": "system", "content": system})
        history.append({"role": "user", "content": question})
        for _ in range(max_rounds):
            response = self.client.chat.completions.create(
                model=self.model, messages=history, tools=tools)
            msg = response.choices[0].message
            history.append(msg.model_dump(exclude_none=True))
            if not msg.tool_calls:
                return msg.content or ""
            for call in msg.tool_calls:
                try:
                    sql = json.loads(call.function.arguments)["sql"]
                    content = clip(execute_sql(sql))
                except Exception as exc:
                    content = str(exc)[:2000]
                history.append({"role": "tool", "tool_call_id": call.id, "content": content})
        return "Stopped after the maximum number of tool-use rounds without a final answer."
