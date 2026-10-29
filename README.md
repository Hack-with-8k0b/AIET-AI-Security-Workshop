# AIET AI Security Workshop

Browser-based AI security training using [AIGoat](./AIGoat/README.md): prompt injection, sensitive-data leakage, RAG poisoning, agent/tool misuse, and MCP security.

## Quick instructor setup (NVIDIA hosted model)

The workshop Docker configuration is being adapted to use NVIDIA's OpenAI-compatible API with `nvidia/nemotron-3-ultra-550b-a55b`. It is intended to avoid local Ollama model downloads and keep the API key on the backend.

### Configure

PowerShell from the repository root:

```powershell
cd AIGoat\docker
Copy-Item .env.example .env
notepad .env
```

Set `NVIDIA_API_KEY` and `APP_SECRET_KEY`. Generate a secret with:

```powershell
python -c "import secrets; print(secrets.token_urlsafe(48))"
```

Never commit or share `docker/.env`.

### Run local smoke test

Keep `HOST_BIND=127.0.0.1` in `.env` for initial testing:

```powershell
docker compose up --build -d
docker compose ps
docker compose logs --tail 100 backend
```

Open http://127.0.0.1:3000. Test login, chat, one RAG lab, one agent lab, and one MCP lab before using it in class.

### Classroom network

Only after testing, set `HOST_BIND` to the instructor PC's actual LAN IP and allow inbound TCP/3000 only from the student subnet using Windows Firewall. Do not use `0.0.0.0`, public port forwarding, or internet exposure. The backend is intended to remain private inside Docker.

Use synthetic data only. NVIDIA API quotas/rate limits can change; a successful single request does not guarantee 60 concurrent students. Pilot with 5–10 students and stagger exercises if rate limits or timeouts occur.

See [the AIGoat workshop guide](./AIGoat/docs/workshop-guide.md).
