#!/usr/bin/env bash
# AIET workshop deploy helper (Linux / Kali / macOS).
# Usage:
#   ./deploy.sh up        # configure check + build/start
#   ./deploy.sh down      # stop stack
#   ./deploy.sh status    # compose ps + HTTP checks
#   ./deploy.sh logs      # tail backend logs
#   ./deploy.sh restart   # down + up
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
    echo "[INFO] Created .env from .env.example — edit NVIDIA_API_KEY and APP_SECRET_KEY, then re-run."
    exit 2
  fi

  # shellcheck disable=SC1091
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a

  if [[ -z "${NVIDIA_API_KEY:-}" ]]; then
    echo "[ERROR] Set NVIDIA_API_KEY in $ROOT/.env" >&2
    exit 1
  fi
  if [[ -z "${APP_SECRET_KEY:-}" || "${APP_SECRET_KEY}" == "aigoat-dev-secret-change-in-production" ]]; then
    echo "[ERROR] Set a unique APP_SECRET_KEY in $ROOT/.env" >&2
    echo "        python3 -c \"import secrets; print(secrets.token_urlsafe(48))\"" >&2
    exit 1
  fi
}

wait_http() {
  local url="$1"
  local tries="${2:-40}"
  local i
  for ((i = 1; i <= tries; i++)); do
    if curl -fsS -o /dev/null "$url"; then
      echo "[OK]   $url"
      return 0
    fi
    sleep 3
  done
  echo "[WARN] Timed out waiting for $url" >&2
  return 1
}

cmd_up() {
  need_cmd docker
  docker compose version >/dev/null
  ensure_env

  echo "[INFO] Building and starting AI Goat (NVIDIA hosted models, distroless backend)..."
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
  echo "[OK]   Stack stopped"
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
