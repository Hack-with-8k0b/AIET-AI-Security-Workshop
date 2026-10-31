#!/usr/bin/env bash
# AIET workshop deploy helper (Linux / Kali / macOS) — Ollama local stack.
# Usage:
#   ./deploy.sh up | down | status | logs | restart
#
# GPU switch (env AIGOAT_GPU, also readable from .env):
#   auto — NVIDIA if nvidia-smi works, else CPU (default)
#   gpu  — always merge docker-compose.gpu.yml
#   cpu  — never request a GPU (works on any machine)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

ACTION="${1:-up}"
COMPOSE_BASE=(-f docker-compose.yml)
COMPOSE_GPU_FILE="docker-compose.gpu.yml"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[ERROR] Missing required command: $1" >&2
    exit 1
  }
}

ensure_env() {
  REPO_ROOT="$(cd "$ROOT/../.." && pwd)"
  if [[ -f "$REPO_ROOT/.env" ]]; then
    cp "$REPO_ROOT/.env" .env
    echo "[INFO] Synced repo-root .env -> AIGoat/docker/.env"
  elif [[ ! -f .env ]]; then
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
    echo "[INFO] Creating Docker volume ollama_models..."
    docker volume create ollama_models >/dev/null
  fi
}

# Returns 0 when we should merge docker-compose.gpu.yml.
want_gpu() {
  local mode
  mode="$(echo "${AIGOAT_GPU:-auto}" | tr '[:upper:]' '[:lower:]')"
  case "$mode" in
    0 | false | no | off | cpu)
      return 1
      ;;
    1 | true | yes | on | gpu)
      return 0
      ;;
    auto | *)
      if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
        return 0
      fi
      return 1
      ;;
  esac
}

compose_args() {
  local args=("${COMPOSE_BASE[@]}")
  if [[ "${1:-}" == "gpu" ]]; then
    args+=(-f "$COMPOSE_GPU_FILE")
  fi
  printf '%s\n' "${args[@]}"
}

compose_up() {
  local mode="$1"
  shift
  # shellcheck disable=SC2046
  docker compose $(compose_args "$mode") up --build -d "$@"
}

compose_down() {
  # Include GPU overlay if present so project teardown is consistent either way.
  if [[ -f "$COMPOSE_GPU_FILE" ]]; then
    docker compose -f docker-compose.yml -f "$COMPOSE_GPU_FILE" down --remove-orphans
  else
    docker compose -f docker-compose.yml down --remove-orphans
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

  if want_gpu; then
    echo "[INFO] AIGOAT_GPU=${AIGOAT_GPU:-auto} — attempting NVIDIA GPU for Ollama"
    if ! compose_up gpu; then
      echo "[WARN] GPU compose failed; falling back to CPU (no NVIDIA reservation)"
      compose_up cpu
    else
      echo "[OK]   Started with GPU overlay ($COMPOSE_GPU_FILE)"
    fi
  else
    echo "[INFO] AIGOAT_GPU=${AIGOAT_GPU:-auto} — starting Ollama on CPU (works without NVIDIA)"
    compose_up cpu
  fi

  echo "[INFO] Waiting for UI..."
  wait_http "http://127.0.0.1:3000/" || true
  wait_http "http://127.0.0.1:3000/api/products/" || true
  # shellcheck disable=SC2046
  docker compose $(compose_args "$(want_gpu && echo gpu || echo cpu)") ps || docker compose ps
  echo ""
  echo "App:  http://127.0.0.1:3000"
  echo "Bind: ${HOST_BIND:-0.0.0.0}:3000"
  echo "GPU:  AIGOAT_GPU=${AIGOAT_GPU:-auto} (set cpu|gpu|auto in .env to force)"
}

cmd_down() {
  need_cmd docker
  # Never pass -v here: workshop DB + Ollama model volumes must survive restarts.
  compose_down
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
    echo "GPU:   AIGOAT_GPU=auto|gpu|cpu (default auto)" >&2
    exit 1
    ;;
esac
