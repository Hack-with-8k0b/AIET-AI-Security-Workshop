# AIET AI Security Workshop

Browser-based AI security labs built on [AIGoat](./AIGoat/README.md): prompt injection, data leakage, RAG poisoning, agent/tool misuse, and MCP security.

## What this deployment uses

| Piece | Implementation |
|---|---|
| Chat LLM | NVIDIA NIM API (`nvidia/nemotron-3-ultra-550b-a55b`) |
| RAG embeddings | NVIDIA NIM API (`nvidia/nv-embedqa-e5-v5`) |
| Vector store | Local ChromaDB volume (no local Torch/CUDA) |
| Backend image | Multi-stage **distroless** Python (`entrypoint.py`) |
| Frontend | Nginx serving the React UI on port **3000** |

No Ollama container and no multi-GB local model download.

## Quick start

```powershell
cd AIGoat\docker
Copy-Item .env.example .env
# Edit .env: set NVIDIA_API_KEY and APP_SECRET_KEY
docker compose up --build -d
```

Open **http://127.0.0.1:3000**.

Generate a secret:

```powershell
python -c "import secrets; print(secrets.token_urlsafe(48))"
```

Never commit `AIGoat/docker/.env`.

## Useful commands

```powershell
cd AIGoat\docker
docker compose ps
docker compose logs --tail 100 backend
docker compose down
```

## Network notes

- Default `HOST_BIND=0.0.0.0` so VM port-forwards / LAN access can reach the UI.
- For loopback-only smoke tests, set `HOST_BIND=127.0.0.1`.
- Do not expose this workshop stack to the public internet.

## Docs

- [AIGoat README](./AIGoat/README.md)
- [Workshop guide](./AIGoat/docs/workshop-guide.md)
