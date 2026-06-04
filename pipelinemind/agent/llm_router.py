"""
LLM Router — routes each call type to the cheapest/fastest model tier.

Call type taxonomy and rationale:
  SUMMARY   → llama-3.1-8b-instant
              Batch summaries at ingestion time.  Quality needed: medium.
              Volume: high.  Function calling: no.

  INTENT    → llama-3.1-8b-instant
              JSON-only output of 2 fields (intent + confidence).
              Needs: zero creativity, deterministic, 50 tokens max.
              Previously used 70b — complete waste of quota.

  HYDE      → llama-3.1-8b-instant
              Hypothetical document generation.  Medium creativity.
              Does NOT need function calling or chain-of-thought depth.
              Previously used 70b — unnecessary.

  AGENT     → llama-3.3-70b-versatile
              Only call type that NEEDS function calling + multi-step reasoning.
              70b stays here and only here.

Rate-limit strategy:
  - Groq free tier: ~14,400 tokens/min for llama3-70b, ~30,000 for llama3-8b
  - By moving INTENT + HYDE to 8b, we free ~60-70% of 70b quota for the agent
  - On 429, tenacity retries with exponential backoff (already in Groq client)
  - If a second GROQ_API_KEY_SECONDARY is set in .env, the router round-robins
    between the two keys on 429 to double effective quota
"""
from __future__ import annotations

import logging
import os
import time
from enum import Enum
from functools import lru_cache
from typing import Any

from groq import Groq, RateLimitError
from tenacity import (
    retry,
    retry_if_exception_type,
    stop_after_attempt,
    wait_exponential,
)

from pm_config import settings

logger = logging.getLogger(__name__)


class CallType(str, Enum):
    SUMMARY = "summary"   # ingestion-time chunk summaries
    INTENT  = "intent"    # query intent classification
    HYDE    = "hyde"      # hypothetical document generation
    AGENT   = "agent"     # function-calling reasoning loop


# Model assignment per call type — all changeable via .env overrides
_MODEL_MAP: dict[CallType, str] = {
    CallType.SUMMARY: settings.groq_model_fast,    # llama-3.1-8b-instant
    CallType.INTENT:  settings.groq_model_fast,    # llama-3.1-8b-instant  (was 70b — fixed)
    CallType.HYDE:    settings.groq_model_fast,    # llama-3.1-8b-instant  (was 70b — fixed)
    CallType.AGENT:   settings.groq_model_agent,   # llama-3.3-70b-versatile
}

# Per-call-type token limits
_MAX_TOKENS: dict[CallType, int] = {
    CallType.SUMMARY: 200,
    CallType.INTENT:  60,
    CallType.HYDE:    250,
    CallType.AGENT:   2048,
}

# Per-call-type temperature
_TEMPERATURE: dict[CallType, float] = {
    CallType.SUMMARY: 0.1,
    CallType.INTENT:  0.0,   # fully deterministic for classification
    CallType.HYDE:    0.35,
    CallType.AGENT:   0.2,
}


@lru_cache(maxsize=4)
def _get_client(api_key: str) -> Groq:
    return Groq(api_key=api_key)


def _primary_client() -> Groq:
    return _get_client(settings.groq_api_key)


def _secondary_client() -> Groq | None:
    """Return a secondary Groq client if GROQ_API_KEY_SECONDARY is configured."""
    secondary = os.environ.get("GROQ_API_KEY_SECONDARY", "").strip()
    if secondary:
        return _get_client(secondary)
    return None


class LLMRouter:
    """
    Routes LLM calls to the appropriate model tier.
    Implements key-rotation on 429 if a secondary key is configured.
    """

    def __init__(self) -> None:
        self._call_counts: dict[str, int] = {}
        self._rate_limit_hits = 0

    def complete(
        self,
        call_type: CallType,
        messages: list[dict],
        tools: list[dict] | None = None,
        tool_choice: str = "auto",
        extra_kwargs: dict | None = None,
    ) -> Any:
        """
        Route a completion request to the correct model tier.
        Automatically falls back to secondary key on 429.
        """
        model      = _MODEL_MAP[call_type]
        max_tokens = _MAX_TOKENS[call_type]
        temperature = _TEMPERATURE[call_type]

        kwargs: dict = {
            "model":       model,
            "messages":    messages,
            "max_tokens":  max_tokens,
            "temperature": temperature,
        }
        if tools:
            kwargs["tools"]       = tools
            kwargs["tool_choice"] = tool_choice
        if extra_kwargs:
            kwargs.update(extra_kwargs)

        # Track call volume per type
        self._call_counts[call_type.value] = self._call_counts.get(call_type.value, 0) + 1

        return self._call_with_fallback(kwargs)

    def _call_with_fallback(self, kwargs: dict) -> Any:
        """Try primary key; on 429 try secondary key once; then let tenacity handle retries."""
        try:
            return _primary_client().chat.completions.create(**kwargs)
        except RateLimitError as exc:
            self._rate_limit_hits += 1
            logger.warning(
                "Groq 429 on primary key (total=%d) | model=%s",
                self._rate_limit_hits, kwargs.get("model"),
            )
            secondary = _secondary_client()
            if secondary:
                logger.info("Attempting secondary Groq key")
                try:
                    return secondary.chat.completions.create(**kwargs)
                except RateLimitError:
                    logger.warning("Secondary key also rate-limited — waiting for tenacity retry")
            raise  # let tenacity in caller handle the final retry

    def stats(self) -> dict:
        return {
            "call_counts":      self._call_counts,
            "rate_limit_hits":  self._rate_limit_hits,
            "model_assignment": {k.value: v for k, v in _MODEL_MAP.items()},
        }


# Module-level singleton — import and use directly
router = LLMRouter()
