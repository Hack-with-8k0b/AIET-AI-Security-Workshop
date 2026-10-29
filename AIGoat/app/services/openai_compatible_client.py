"""OpenAI-compatible hosted LLM client (NVIDIA NIM and compatible APIs).

Uses the existing AIGoat LLM protocol so the lab surfaces, challenges, and
agent can share one hosted model without running local inference.
"""
from __future__ import annotations

import asyncio
import json
import logging
from collections.abc import AsyncIterator
from typing import Any

import httpx

from app.services.llm_protocol import ChatTurn

logger = logging.getLogger(__name__)


class OpenAICompatibleClient:
    def __init__(
        self,
        base_url: str,
        api_key: str,
        model: str,
        timeout: int = 120,
    ) -> None:
        if not api_key.strip():
            raise RuntimeError(
                "NVIDIA_API_KEY is required when LLM_PROVIDER=nvidia. "
                "Set it in the instructor-only .env file; never commit it."
            )
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.timeout = timeout
        self._http = httpx.AsyncClient(
            base_url=self.base_url,
            headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
            timeout=httpx.Timeout(timeout, connect=15.0),
        )

    @staticmethod
    def _completion_options(options: dict[str, Any] | None) -> dict[str, Any]:
        if not options:
            return {}
        mapped: dict[str, Any] = {}
        for source, target in (
            ("temperature", "temperature"),
            ("top_p", "top_p"),
            ("num_predict", "max_tokens"),
            ("max_tokens", "max_tokens"),
            ("seed", "seed"),
            ("stop", "stop"),
        ):
            if source in options and options[source] is not None:
                mapped[target] = options[source]
        return mapped

    async def check_health(self) -> bool:
        try:
            response = await self._http.get("/models")
            return response.status_code == 200
        except Exception as exc:
            logger.warning("Hosted LLM health check failed: %s", type(exc).__name__)
            return False

    async def generate(
        self,
        prompt: str,
        system: str = "",
        options: dict[str, Any] | None = None,
    ) -> str:
        messages: list[dict[str, Any]] = []
        if system:
            messages.append({"role": "system", "content": system})
        messages.append({"role": "user", "content": prompt})
        payload = {
            "model": self.model,
            "messages": messages,
            "stream": False,
            **self._completion_options(options),
        }
        try:
            response = await self._http.post("/chat/completions", json=payload)
            response.raise_for_status()
            choices = response.json().get("choices") or []
            message = choices[0].get("message", {}) if choices else {}
            return str(message.get("content") or "")
        except Exception as exc:
            logger.error("Hosted LLM generation failed: %s", type(exc).__name__)
            return ""

    async def generate_stream(
        self,
        prompt: str,
        system: str = "",
        options: dict[str, Any] | None = None,
        stop: asyncio.Event | None = None,
    ) -> AsyncIterator[str]:
        messages: list[dict[str, Any]] = []
        if system:
            messages.append({"role": "system", "content": system})
        messages.append({"role": "user", "content": prompt})
        payload = {
            "model": self.model,
            "messages": messages,
            "stream": True,
            **self._completion_options(options),
        }
        try:
            async with self._http.stream(
                "POST", "/chat/completions", json=payload
            ) as response:
                response.raise_for_status()
                async for line in response.aiter_lines():
                    if stop is not None and stop.is_set():
                        return
                    if not line or not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if data == "[DONE]":
                        return
                    try:
                        event = json.loads(data)
                        choices = event.get("choices") or []
                        delta = choices[0].get("delta", {}) if choices else {}
                        token = delta.get("content")
                        if isinstance(token, str) and token:
                            yield token
                    except (json.JSONDecodeError, AttributeError, IndexError, TypeError):
                        continue
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            if stop is None or not stop.is_set():
                logger.error("Hosted LLM streaming failed: %s", type(exc).__name__)

    async def chat(
        self,
        messages: list[dict[str, str]],
        system: str = "",
        options: dict[str, Any] | None = None,
        tools: list[dict[str, Any]] | None = None,
        model: str | None = None,
    ) -> str:
        turn = await self.chat_turn(
            messages, system=system, options=options, tools=tools, model=model
        )
        return turn.content

    async def chat_turn(
        self,
        messages: list[dict[str, Any]],
        system: str = "",
        options: dict[str, Any] | None = None,
        tools: list[dict[str, Any]] | None = None,
        model: str | None = None,
    ) -> ChatTurn:
        chat_messages = list(messages)
        if system:
            chat_messages.insert(0, {"role": "system", "content": system})
        payload: dict[str, Any] = {
            "model": model or self.model,
            "messages": chat_messages,
            "stream": False,
            **self._completion_options(options),
        }
        if tools:
            payload["tools"] = tools
        try:
            response = await self._http.post("/chat/completions", json=payload)
            response.raise_for_status()
            choices = response.json().get("choices") or []
            message = choices[0].get("message", {}) if choices else {}
            calls: list[dict[str, Any]] = []
            for raw in message.get("tool_calls") or []:
                function = raw.get("function") or {}
                arguments = function.get("arguments") or {}
                if isinstance(arguments, str):
                    try:
                        arguments = json.loads(arguments)
                    except json.JSONDecodeError:
                        arguments = {}
                if not isinstance(arguments, dict):
                    arguments = {}
                name = function.get("name")
                if name:
                    calls.append({"name": str(name), "arguments": arguments})
            return ChatTurn(
                content=str(message.get("content") or ""),
                tool_calls=calls,
                assistant_message=message if calls else None,
            )
        except Exception as exc:
            logger.error("Hosted LLM chat failed: %s", type(exc).__name__)
            return ChatTurn(content="", tool_calls=[])
