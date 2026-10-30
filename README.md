# AIET AI Security Workshop

Browser-based AI security labs built on [AIGoat](./AIGoat/README.md): prompt injection, data leakage, RAG poisoning, agent/tool misuse, and MCP security.

Runs **fully locally** with **Ollama** (no cloud API key). One PowerShell script starts Docker and publishes the site via **DuckDNS** + **Cloudflare Tunnel**.

## Quick start (Windows 11)

```powershell
git clone <this-repo-url>
cd AIET-AI-Security-Workshop

Copy-Item .env.example .env
notepad .env
# Set:
#   DUCKDNS_DOMAIN=your-subdomain
#   DUCKDNS_TOKEN=your-token

.\Enable-Access.ps1
```

That single command will:

1. Sync `.env` into `AIGoat\docker\.env`
2. Create the `ollama_models` volume if needed
3. Run `docker compose up --build -d`
4. Wait for the UI on port 3000
5. Install DuckDNS updater + Cloudflare Tunnel
6. Print the public link

```text
============================================================
  ACCESS THE WORKSHOP HERE (Cloudflare Tunnel)
============================================================

  https://….trycloudflare.com
```

Also saved to `remote\state\tunnel-url.txt`.

| Access | URL |
|---|---|
| **Use this** | Cloudflare link printed by the script |
| Local | http://127.0.0.1:3000 |
| DuckDNS direct | http://YOURNAME.duckdns.org:3000 (only if router forwards TCP 3000) |

**First run:** Docker Desktop needs **12 GB+ RAM**. First start builds images and pulls **mistral** (~4.5 GB).

## Folder layout

```text
.
├── Enable-Access.ps1     <- only script you need
├── .env.example          <- copy to .env; fill DuckDNS
├── remote/state/         <- tunnel URL + runtime (gitignored)
└── AIGoat/docker/        <- docker compose stack
```

## Configure (`.env`)

| Variable | Required | Purpose |
|---|---|---|
| `DUCKDNS_DOMAIN` | yes | Subdomain only (e.g. `aeit-aisec1`) |
| `DUCKDNS_TOKEN` | yes | Token from [duckdns.org](https://www.duckdns.org) |
| `HOST_BIND` | no | Default `0.0.0.0` |
| `LLM_PROVIDER` | no | Default `ollama` |
| `APP_SECRET_KEY` | no | Default workshop local secret |

**Never commit `.env`.** No NVIDIA / API keys are required.

## Useful commands

```powershell
.\Enable-Access.ps1                 # full start (compose + tunnel)
.\Enable-Access.ps1 -Status         # show tunnel link again
.\Enable-Access.ps1 -RestartTunnel  # new Cloudflare URL
.\Enable-Access.ps1 -SkipCompose    # tunnel/DNS only (app already up)
.\Enable-Access.ps1 -Uninstall      # remove tasks + stop tunnel

cd AIGoat\docker
docker compose ps
docker compose logs -f backend
docker compose down
```

## Architecture

| Piece | Implementation |
|---|---|
| Chat LLM | Ollama (`mistral`) |
| RAG embeddings | Local `all-MiniLM-L6-v2` |
| UI | http://127.0.0.1:3000 |
| Public HTTPS | Cloudflare quick tunnel |
| DNS name | DuckDNS updater |

AIGoat is **intentionally vulnerable** — keep tunnels short-lived for workshops only.

## Troubleshooting

| Symptom | Fix |
|---|---|
| UI not up | Wait for mistral pull; `docker compose -f AIGoat\docker\docker-compose.yml logs` |
| Docker OOM | Raise Docker Desktop memory to 12 GB+ |
| No tunnel URL | `.\Enable-Access.ps1 -RestartTunnel` |
| DuckDNS times out in browser | Expected without port-forward — use the Cloudflare link |

## Docs

- [Remote runtime notes](./remote/README.md)
- [Instructor workshop guide](./AIGoat/docs/workshop-guide.md)
- [AIGoat README](./AIGoat/README.md)
