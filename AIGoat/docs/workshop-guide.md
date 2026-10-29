# AIET AI Security Workshop — Instructor Setup

Instructor-hosted browser lab using AIGoat with **NVIDIA hosted** chat and embeddings (no Ollama). Exercises cover prompt injection, sensitive-data leakage, RAG poisoning, agent misuse/memory poisoning, and MCP security.

## Prerequisites

- Docker Engine + Compose v2 (Docker Desktop on Windows/macOS, or Docker on Linux/Kali)
- NVIDIA API key with access to the configured chat + embedding models
- Stable outbound HTTPS to `https://integrate.api.nvidia.com`

## Configure

```powershell
cd AIGoat\docker
Copy-Item .env.example .env
notepad .env
```

On Linux/Kali:

```bash
cd AIGoat/docker
cp .env.example .env
nano .env
```

Required:

- `NVIDIA_API_KEY`
- `APP_SECRET_KEY` (unique per deployment)

```powershell
python -c "import secrets; print(secrets.token_urlsafe(48))"
```

Optional knobs (defaults are fine for the workshop):

- `NVIDIA_MODEL=nvidia/nemotron-3-ultra-550b-a55b`
- `NVIDIA_EMBED_MODEL=nvidia/nv-embedqa-e5-v5`
- `HOST_BIND=127.0.0.1` for local-only, or `0.0.0.0` for VM/LAN

Never commit `.env` or share the NVIDIA key with students.

## Deploy

### Helper scripts (recommended)

Windows:

```powershell
cd AIGoat\docker
.\deploy.ps1 up
.\deploy.ps1 status
```

Linux / Kali:

```bash
cd AIGoat/docker
chmod +x deploy.sh
./deploy.sh up
./deploy.sh status
```

### Manual Compose

```bash
cd AIGoat/docker
docker compose up --build -d
docker compose ps
docker compose logs --tail 100 backend
```

Open http://127.0.0.1:3000. Validate sign-up/login, chat, one RAG lab, one agent lab, and one MCP lab. Stop with `./deploy.sh down` / `.\deploy.ps1 down` or `docker compose down`.

## Classroom access

1. Confirm the stack is healthy locally (`deploy.* status`).
2. Set `HOST_BIND` to `0.0.0.0` **or** the instructor machine LAN IP.
3. Allow inbound TCP/3000 only from the classroom subnet (firewall).
4. If students reach a Linux VM from Windows, forward guest port **3000**.
5. Test from one student PC before sharing the URL.
6. Do not use public port forwarding or internet exposure.

Only the frontend is published. Backend, SQLite, and Chroma data stay on the private Docker network / named volume. Use synthetic data and individual student accounts.

## Capacity and safety

NVIDIA quotas/rate limits vary. One successful API call does not prove 60 concurrent students will work. Pilot with 5–10 participants, expand gradually, watch for HTTP 429/timeouts, and stagger model-heavy exercises. Keep the API key and app secret instructor-only.

## Troubleshooting

| Issue | Action |
|---|---|
| Missing key/secret | Edit `docker/.env`, then `deploy.* restart` |
| Backend unhealthy | `deploy.* logs` — look for NVIDIA auth or startup errors |
| Cannot `docker exec` into backend | Expected for distroless; use logs/status helpers |
| UI blank / API failing from another machine | Check `HOST_BIND` and port-forward/firewall for TCP 3000 |
