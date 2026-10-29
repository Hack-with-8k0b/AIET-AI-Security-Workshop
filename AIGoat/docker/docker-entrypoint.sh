#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# AI Goat -- Docker Entrypoint (Backend)
#
# 1. Ensures the configured Ollama model is available (pulls
#    only on first run; skips if already present).
# 2. Initializes the database and seeds demo data.
# 3. Starts the FastAPI backend with uvicorn.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }

PROVIDER="${LLM_PROVIDER:-ollama}"

echo ""
echo "=========================================="
echo "   AI Goat -- Docker Backend Starting     "
echo "=========================================="
echo ""

# ── Step 1: Validate the selected model provider ───────────────
if [[ "$PROVIDER" == "nvidia" || "$PROVIDER" == "openai-compatible" || "$PROVIDER" == "openai_compatible" ]]; then
    if [[ -z "${NVIDIA_API_KEY:-}" ]]; then
        echo "[ERROR] NVIDIA_API_KEY is required when LLM_PROVIDER=$PROVIDER." >&2
        exit 1
    fi
    if [[ -z "${APP_SECRET_KEY:-}" || "$APP_SECRET_KEY" == "aigoat-dev-secret-change-in-production" ]]; then
        echo "[ERROR] Set a unique APP_SECRET_KEY in docker/.env before starting." >&2
        exit 1
    fi
    info "Using hosted NVIDIA model ${NVIDIA_MODEL:-nvidia/nemotron-3-ultra-550b-a55b}; no local model will be downloaded."
elif [[ "$PROVIDER" == "ollama" ]]; then
    OLLAMA_URL="${OLLAMA_BASE_URL:-http://ollama:11434}"
    MODEL=$(python -c "from app.core.config import load_config; print(load_config().ollama.model)" 2>/dev/null || echo "mistral")
    info "Checking whether Ollama model '$MODEL' is available..."
    MODEL_EXISTS=$(python -c "
import httpx, sys
try:
    r = httpx.get('$OLLAMA_URL/api/tags', timeout=10)
    names = [m.get('name','') for m in r.json().get('models', [])]
    print('yes' if any('$MODEL' in n for n in names) else 'no')
except Exception:
    print('no')
" || echo "no")
    if [[ "$MODEL_EXISTS" != "yes" ]]; then
        info "Pulling Ollama model '$MODEL'..."
        python -c "import httpx; r=httpx.post('$OLLAMA_URL/api/pull', json={'name':'$MODEL','stream':False}, timeout=None); r.raise_for_status()"
    fi
else
    echo "[ERROR] Unsupported LLM_PROVIDER='$PROVIDER'. Use 'nvidia' or 'ollama'." >&2
    exit 1
fi

# ── Step 2: Database initialization ───────────────────────────
info "Applying database migrations..."
DB_FILE="${DB_FILE:-/app/data/aigoat.db}"
if [ -f "$DB_FILE" ]; then
    # 0001 matches the pre-Alembic schema. Stamp that revision, then upgrade, so later
    # migrations still run. Stamping head would mark them applied without running them.
    DB_STATE=$(python -c "
import sqlite3
try:
    names = {row[0] for row in sqlite3.connect('$DB_FILE').execute(\"SELECT name FROM sqlite_master WHERE type='table'\")}
except Exception:
    names = set()
if 'alembic_version' in names:
    print('current')
elif 'users' in names:
    print('baseline')
else:
    print('empty')
")
    if [ "$DB_STATE" = "baseline" ]; then
        info "Pre-Alembic database detected. Stamping revision 0001, then applying later migrations. Data is kept."
        python -m alembic stamp 0001
    fi
fi
python -m alembic upgrade head
ok "Database schema ready"

# ── Step 3: Seed data (idempotent) ────────────────────────────
info "Checking seed data..."
NEEDS_SEED=$(python -c "
import asyncio
from app.core.database import async_session, init_db
from sqlalchemy import select, func
from app.models import User, Product

async def check():
    await init_db()
    async with async_session() as db:
        users = (await db.execute(select(func.count(User.id)))).scalar() or 0
        products = (await db.execute(select(func.count(Product.id)))).scalar() or 0
        if users < 5 or products < 20:
            print('yes')
        else:
            print('no')
asyncio.run(check())
" 2>/dev/null || echo "yes")

if [ "$NEEDS_SEED" = "yes" ]; then
    info "Seeding demo data (users, products, challenges, knowledge base)..."
    python -m scripts.seed
    ok "Demo data seeded"
else
    ok "Database already has required data"
fi

info "Syncing support tickets..."
python -m scripts.seed --sync-support
ok "Support tickets ready"

# Refresh challenge title/description/owasp_ref/hints/etc. from CHALLENGE_DEFINITIONS
# without wiping ChallengeAttempt (full seed deletes attempts; this sync does not).
info "Syncing challenge metadata..."
python -m scripts.seed --sync-challenges
ok "Challenge metadata synced"

# ── Step 4: Start backend ─────────────────────────────────────
info "Starting uvicorn on 0.0.0.0:${BACKEND_PORT:-8000}..."
exec python -m uvicorn app.main:app \
    --host 0.0.0.0 \
    --port "${BACKEND_PORT:-8000}" \
    --log-level info
