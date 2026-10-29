from __future__ import annotations

import asyncio
import os
from typing import TYPE_CHECKING, Protocol

import httpx

from app.core.config import get_settings

if TYPE_CHECKING:
    from sentence_transformers import SentenceTransformer


class EmbeddingClient(Protocol):
    def embed_text(self, text: str) -> list[float]: ...
    def embed_batch(self, texts: list[str]) -> list[list[float]]: ...


_embedding_service: EmbeddingClient | None = None
_embedding_override: EmbeddingClient | None = None


class EmbeddingService:
    """Local MiniLM embeddings via sentence-transformers (dev / Ollama path)."""

    def __init__(self, model_name: str | None = None) -> None:
        self._model_name = model_name or get_settings().rag.embedding_model
        self._model: SentenceTransformer | None = None

    def _load_model(self) -> SentenceTransformer:
        if self._model is None:
            from sentence_transformers import SentenceTransformer

            self._model = SentenceTransformer(self._model_name)
        return self._model

    def embed_text(self, text: str) -> list[float]:
        model = self._load_model()
        return model.encode(text, convert_to_numpy=True).tolist()

    def embed_batch(self, texts: list[str]) -> list[list[float]]:
        model = self._load_model()
        embeddings = model.encode(texts, convert_to_numpy=True)
        return [emb.tolist() for emb in embeddings]

    async def embed_text_async(self, text: str) -> list[float]:
        return await asyncio.to_thread(self.embed_text, text)

    async def embed_batch_async(self, texts: list[str]) -> list[list[float]]:
        return await asyncio.to_thread(self.embed_batch, texts)


class NvidiaEmbeddingService:
    """Hosted NVIDIA NIM embeddings (OpenAI-compatible /v1/embeddings).

    Uses input_type=query for single-text calls and input_type=passage for
    batches, matching AI Goat's retrieve-vs-index call sites.
    """

    def __init__(
        self,
        base_url: str | None = None,
        api_key: str | None = None,
        model: str | None = None,
        timeout: float = 60.0,
    ) -> None:
        self.base_url = (
            base_url
            or os.environ.get("NVIDIA_BASE_URL")
            or "https://integrate.api.nvidia.com/v1"
        ).rstrip("/")
        self.api_key = (api_key or os.environ.get("NVIDIA_API_KEY") or "").strip()
        self.model = (
            model
            or os.environ.get("NVIDIA_EMBED_MODEL")
            or "nvidia/nv-embedqa-e5-v5"
        )
        if not self.api_key:
            raise RuntimeError(
                "NVIDIA_API_KEY is required for hosted embeddings "
                "(LLM_PROVIDER=nvidia)."
            )
        self._http = httpx.Client(
            base_url=self.base_url,
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
            timeout=httpx.Timeout(timeout, connect=15.0),
        )

    def _embed(self, texts: list[str], input_type: str) -> list[list[float]]:
        if not texts:
            return []
        payload = {
            "input": texts if len(texts) > 1 else texts[0],
            "model": self.model,
            "input_type": input_type,
            "encoding_format": "float",
        }
        # Some NVIDIA embed models accept list input; normalize to list always.
        payload["input"] = texts
        resp = self._http.post("/embeddings", json=payload)
        resp.raise_for_status()
        data = resp.json().get("data") or []
        data_sorted = sorted(data, key=lambda row: row.get("index", 0))
        return [row["embedding"] for row in data_sorted]

    def embed_text(self, text: str) -> list[float]:
        return self._embed([text], input_type="query")[0]

    def embed_batch(self, texts: list[str]) -> list[list[float]]:
        # Index/ingest path — passage mode.
        batch_size = 32
        out: list[list[float]] = []
        for i in range(0, len(texts), batch_size):
            out.extend(self._embed(texts[i : i + batch_size], input_type="passage"))
        return out

    async def embed_text_async(self, text: str) -> list[float]:
        return await asyncio.to_thread(self.embed_text, text)

    async def embed_batch_async(self, texts: list[str]) -> list[list[float]]:
        return await asyncio.to_thread(self.embed_batch, texts)


def set_embedding_override(client: EmbeddingClient | None) -> None:
    """Tests only. Swap the MiniLM model for a hash embedder."""
    global _embedding_override
    _embedding_override = client


def clear_embedding_override() -> None:
    set_embedding_override(None)


def _use_nvidia_embeddings() -> bool:
    provider = os.environ.get("LLM_PROVIDER", "ollama").strip().lower()
    embed_provider = os.environ.get("EMBEDDING_PROVIDER", "").strip().lower()
    if embed_provider in {"nvidia", "openai-compatible", "openai_compatible"}:
        return True
    if embed_provider in {"local", "sentence-transformers", "minilm"}:
        return False
    return provider in {"nvidia", "openai-compatible", "openai_compatible"}


def get_embedding_service() -> EmbeddingClient:
    global _embedding_service
    if _embedding_override is not None:
        return _embedding_override
    if _embedding_service is None:
        if _use_nvidia_embeddings():
            _embedding_service = NvidiaEmbeddingService()
        else:
            _embedding_service = EmbeddingService()
    return _embedding_service
