"""The model seam: choose an LLM backend, symmetric to the store seam.

`open_model()` reads CHDB_MODEL (env or arg) as `provider:name[@base_url]`:

    anthropic:claude-opus-4-8         reference backend (needs [anthropic])
    openai:gpt-4.1                    OpenAI (needs [openai])
    openai:llama3@http://host/v1      any OpenAI-compatible server (Ollama,
                                      vLLM, Gemini compat, …) via base_url
    qwen:qwen-max                     Alibaba Qwen via DashScope's OpenAI-
                                      compatible endpoint (needs [openai];
                                      reads DASHSCOPE_API_KEY)

Adding a provider is one small adapter implementing ModelBackend.run_analyst
— the analyst core (agent.py) never changes.
"""
from __future__ import annotations

import os

from ..errors import MissingDependency
from .base import ModelBackend, clip  # re-exported for adapters

# DashScope OpenAI-compatible endpoint (international). Use the China endpoint
# https://dashscope.aliyuncs.com/compatible-mode/v1 via @base_url if needed.
_QWEN_BASE_URL = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"

__all__ = ["open_model", "missing_credential", "ModelBackend", "clip"]

DEFAULT = "anthropic:claude-opus-4-8"

# which API-key env each provider needs — so /ask can give a clean 503
# ("set this key") instead of a 502 from a failed model construction
_KEY_ENV = {
    "anthropic": "ANTHROPIC_API_KEY",
    "openai": "OPENAI_API_KEY",
    "qwen": "DASHSCOPE_API_KEY",
}


def missing_credential(spec: str | None = None) -> str | None:
    """Return the name of the missing API-key env for the selected model, or
    None if it's set. Lets the app disable /ask cleanly without importing any
    provider SDK."""
    spec = spec or os.getenv("CHDB_MODEL", DEFAULT)
    provider, _, rest = spec.partition(":")
    # an openai:model@base_url points at a self-hosted / compat server
    # (Ollama, vLLM, …) that needs no OpenAI key — don't demand one
    if provider == "openai" and "@" in rest:
        return None
    env = _KEY_ENV.get(provider)
    if env and not os.getenv(env):
        # qwen also accepts OPENAI_API_KEY as a fallback (see open_model)
        if provider == "qwen" and os.getenv("OPENAI_API_KEY"):
            return None
        return env
    return None


def open_model(spec: str | None = None) -> ModelBackend:
    spec = spec or os.getenv("CHDB_MODEL", DEFAULT)
    provider, _, rest = spec.partition(":")
    name, _, base_url = rest.partition("@")
    if provider == "anthropic":
        try:
            from .anthropic import AnthropicModel
        except ImportError as exc:
            raise MissingDependency("anthropic models need: pip install chdb-serverless[anthropic]") from exc
        return AnthropicModel(name or "claude-opus-4-8")
    if provider == "openai":
        try:
            from .openai import OpenAIModel
        except ImportError as exc:
            raise MissingDependency("openai models need: pip install chdb-serverless[openai]") from exc
        return OpenAIModel(name or "gpt-4.1", base_url=base_url or None)
    if provider == "qwen":
        # Qwen speaks the OpenAI-compatible protocol via DashScope, so it
        # reuses the OpenAI backend — just wired to DashScope's URL + key.
        try:
            from .openai import OpenAIModel
        except ImportError as exc:
            raise MissingDependency("qwen models need: pip install chdb-serverless[openai]") from exc
        return OpenAIModel(
            name or "qwen-max",
            base_url=base_url or _QWEN_BASE_URL,
            api_key=os.getenv("DASHSCOPE_API_KEY") or os.getenv("OPENAI_API_KEY"),
        )
    raise ValueError(f"unknown model provider {provider!r} in {spec!r}")
