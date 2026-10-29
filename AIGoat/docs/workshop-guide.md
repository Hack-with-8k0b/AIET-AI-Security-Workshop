# AIET AI Security Workshop — Instructor Setup

This guide describes the instructor-hosted browser lab using AIGoat. Exercises include prompt injection, sensitive-data leakage, RAG poisoning, agent misuse/memory poisoning, and MCP security.

## Quick setup (PowerShell)

Prerequisites: Docker Desktop/Compose, a working NVIDIA API key with model access, and a stable internet connection.

```powershell
cd AIGoat\docker
Copy-Item .env.example .env
notepad .env
```

Set `NVIDIA_API_KEY`. Generate a unique app secret and set `APP_SECRET_KEY`:

```powershell
python -c "import secrets; print(secrets.token_urlsafe(48))"
```

Keep `HOST_BIND=127.0.0.1` for the first test. Never commit `.env` or share the NVIDIA key with students.

```powershell
docker compose up --build -d
docker compose ps
docker compose logs --tail 100 backend
```

Open http://127.0.0.1:3000. Test sign-up/login, chat, one RAG exercise, one agent exercise, and one MCP exercise. Check logs for authentication, model, timeout, or quota errors. Stop with `docker compose down`.

## Enable classroom access

1. Find the instructor machine's LAN IPv4 address.
2. Set `HOST_BIND` in `docker/.env` to that exact address, not `0.0.0.0`.
3. Restrict inbound TCP/3000 in Windows Firewall to the classroom subnet.
4. Test from one student PC before sharing the URL.
5. Do not use public port forwarding or expose this intentionally vulnerable lab to the internet.

Only the frontend should be published to the host; backend and database should remain on the private Docker network. Use synthetic data only and issue individual student accounts.

## Capacity and safety

NVIDIA quotas/rate limits vary. A single successful API request is not evidence that 60 concurrent students will work. Pilot with 5–10 participants, expand gradually, monitor 429/timeouts, and stagger model-intensive exercises. Keep the API key and app secret instructor-only.
