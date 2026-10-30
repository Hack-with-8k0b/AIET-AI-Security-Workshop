#!/usr/bin/env bash
# AIET workshop deploy helper (Linux / Kali / macOS) — Ollama local stack.
# Usage:
#   ./deploy.sh up | down | status | logs | restart
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

ACTION="${1:-up}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[ERROR] Missing required command: $1" >&2
    exit 1
  }
}

ensure_env() {
  if [[ ! -f .env ]]; then
    if [[ ! -f .env.example ]]; then
      echo "[ERROR] .env.example not found in $ROOT" >&2
      exit 1
    fi
    cp .env.example .env
    echo "[INFO] Created .env from .env.example — set DUCKDNS_* if you need remote access."
  fi

  # shellcheck disable=SC1091
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a

  if [[ -z "${APP_SECRET_KEY:-}" ]]; then
    echo "APP_SECRET_KEY=aiet-workshop-local-secret" >> .env
    APP_SECRET_KEY=aiet-workshop-local-secret
    echo "[INFO] Wrote default APP_SECRET_KEY into .env"
  fi
}

ensure_ollama_volume() {
  if ! docker volume ls --format '{{.Name}}' | grep -qx 'ollama_models'; then
    echo "[INFO] Creating external Docker volume ollama_models..."
    docker volume create ollama_models >/dev/null
  fi
}

wait_http() {
  local url="$1"
  local tries="${2:-60}"
  local i
  for ((i = 1; i <= tries; i++)); do
    if curl -fsS -o /dev/null "$url"; then
      echo "[OK]   $url"
      return 0
    fi
    sleep 5
  done
  echo "[WARN] Timed out waiting for $url" >&2
  return 1
}

cmd_up() {
  need_cmd docker
  docker compose version >/dev/null
  ensure_env
  ensure_ollama_volume

  echo "[INFO] Building and starting AI Goat (Ollama + local embeddings)..."
  echo "[INFO] First run may take a long time (image build + mistral model pull)."
  docker compose up --build -d

  echo "[INFO] Waiting for UI..."
  wait_http "http://127.0.0.1:3000/" || true
  wait_http "http://127.0.0.1:3000/api/products/" || true
  docker compose ps
  echo ""
  echo "App:  http://127.0.0.1:3000"
  echo "Bind: ${HOST_BIND:-0.0.0.0}:3000"
}

cmd_down() {
  need_cmd docker
  docker compose down --remove-orphans
  echo "[OK]   Stack stopped (ollama_models volume kept)"
}

cmd_status() {
  need_cmd docker
  docker compose ps -a
  echo ""
  curl -s -o /dev/null -w "ui:  %{http_code}\n" http://127.0.0.1:3000/ || echo "ui:  down"
  curl -s -o /dev/null -w "api: %{http_code}\n" http://127.0.0.1:3000/api/products/ || echo "api: down"
}

cmd_logs() {
  need_cmd docker
  docker compose logs --tail "${2:-100}" -f backend
}

cmd_restart() {
  cmd_down
  cmd_up
}

case "$ACTION" in
  up) cmd_up ;;
  down) cmd_down ;;
  status) cmd_status ;;
  logs) cmd_logs "$@" ;;
  restart) cmd_restart ;;
  *)
    echo "Usage: $0 {up|down|status|logs|restart}" >&2
    exit 1
    ;;
esac
