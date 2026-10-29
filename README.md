# AIET AI Security Workshop

Browser-based AI security labs built on [AIGoat](./AIGoat/README.md): prompt injection, data leakage, RAG poisoning, agent/tool misuse, and MCP security.

## Architecture (this workshop deployment)

| Piece | Implementation |
|---|---|
| Chat LLM | NVIDIA NIM API (`nvidia/nemotron-3-ultra-550b-a55b`) |
| RAG embeddings | NVIDIA NIM API (`nvidia/nv-embedqa-e5-v5`) |
| Vector store | Local ChromaDB volume (no local Torch/CUDA) |
| Backend | Distroless Python image, started by `entrypoint.py` |
| Frontend | Nginx UI on host port **3000** |

There is **no Ollama service** and no multi-GB local model download. First image build still takes several minutes (Python deps + frontend).

## Prerequisites

- Docker Engine + Docker Compose v2
- NVIDIA API key from [build.nvidia.com](https://build.nvidia.com/)
- Outbound HTTPS to `integrate.api.nvidia.com`

## Configure

```powershell
cd AIGoat\docker
Copy-Item .env.example .env
```

Edit `.env` and set at least:

| Variable | Purpose |
|---|---|
| `NVIDIA_API_KEY` | Hosted chat + embeddings |
| `APP_SECRET_KEY` | App signing / session secret |
| `HOST_BIND` | `127.0.0.1` (local only) or `0.0.0.0` (VM / LAN) |
| `NVIDIA_MODEL` | Chat model (default Nemotron Ultra) |
| `NVIDIA_EMBED_MODEL` | Embedding model (default `nv-embedqa-e5-v5`) |

Generate a secret:

```powershell
python -c "import secrets; print(secrets.token_urlsafe(48))"
```

**Never commit `AIGoat/docker/.env`.**

## Deploy helpers

Scripts live in `AIGoat/docker/`.

### Windows (PowerShell)

```powershell
cd AIGoat\docker
.\deploy.ps1 up        # create/check .env, build, start, smoke-check
.\deploy.ps1 status    # compose ps + HTTP checks
.\deploy.ps1 logs      # follow backend logs
.\deploy.ps1 down      # stop stack
.\deploy.ps1 restart
```

### Linux / Kali / macOS

```bash
cd AIGoat/docker
chmod +x deploy.sh
./deploy.sh up
./deploy.sh status
./deploy.sh logs
./deploy.sh down
./deploy.sh restart
```

### Manual Compose (any OS)

```bash
cd AIGoat/docker
cp -n .env.example .env   # first time only
docker compose up --build -d
docker compose ps
```

Open **http://127.0.0.1:3000**.

## Smoke test checklist

After `up` / `status` shows healthy:

1. Sign up / log in
2. Send a short chat message (NVIDIA chat path)
3. Open one RAG lab (NVIDIA embeddings path)
4. Open one agent lab and one MCP lab
5. Confirm `docker compose logs backend` has no auth/quota errors

## Operations

```bash
# Status
docker compose -f AIGoat/docker/docker-compose.yml ps

# Backend logs
docker compose -f AIGoat/docker/docker-compose.yml logs --tail 100 backend

# Rebuild backend only after code changes
cd AIGoat/docker && docker compose build backend && docker compose up -d

# Reset app data volume (destructive)
cd AIGoat/docker && docker compose down -v
```

## Network / classroom notes

- Default `HOST_BIND=0.0.0.0` so hypervisor port-forwards and LAN clients can reach `:3000`.
- For instructor-only smoke tests on one machine, use `HOST_BIND=127.0.0.1`.
- Publish **only** the frontend port. Backend stays on the Docker network.
- Do **not** expose this intentionally vulnerable lab to the public internet.
- NVIDIA rate limits vary — pilot with a small group before a full class.

## Troubleshooting

| Symptom | Likely fix |
|---|---|
| `NVIDIA_API_KEY is required` | Fill `AIGoat/docker/.env` and restart |
| Backend restart loop | `./deploy.sh logs` / `.\deploy.ps1 logs` and check secret/key |
| UI not reachable from Windows host into a Linux VM | Forward guest TCP **3000**, keep `HOST_BIND=0.0.0.0` |
| Build is slow first time | Expected; later rebuilds use Docker layer cache |
| Distroless has no shell | Use `docker compose logs` / `deploy.* status` — do not `docker exec bash` |

## Docs

- [Instructor workshop guide](./AIGoat/docs/workshop-guide.md)
- [AIGoat project README](./AIGoat/README.md)
