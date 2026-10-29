#!/usr/bin/env bash
# AI Goat backend entrypoint (NVIDIA workshop path).
set -euo pipefail

info() { echo "[INFO] $*"; }
ok()   { echo "[OK]   $*"; }

PROVIDER="${LLM_PROVIDER:-nvidia}"

echo ""
echo "=========================================="
echo "   AI Goat -- Docker Backend Starting     "
echo "=========================================="
echo ""

if [[ "$PROVIDER" != "nvidia" && "$PROVIDER" != "openai-compatible" && "$PROVIDER" != "openai_compatible" ]]; then
  echo "[ERROR] This workshop image expects LLM_PROVIDER=nvidia (got '$PROVIDER')." >&2
  exit 1
fi

if [[ -z "${NVIDIA_API_KEY:-}" ]]; then
  echo "[ERROR] NVIDIA_API_KEY is required." >&2
  exit 1
fi

if [[ -z "${APP_SECRET_KEY:-}" || "$APP_SECRET_KEY" == "aigoat-dev-secret-change-in-production" ]]; then
  echo "[ERROR] Set a unique APP_SECRET_KEY in docker/.env." >&2
  exit 1
fi

info "NVIDIA model: ${NVIDIA_MODEL:-nvidia/nemotron-3-ultra-550b-a55b}"

info "Applying database migrations..."
DB_FILE="${DB_FILE:-/app/data/aigoat.db}"
if [ -f "$DB_FILE" ]; then
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
    info "Pre-Alembic DB detected; stamping 0001 then upgrading."
    python -m alembic stamp 0001
  fi
fi
python -m alembic upgrade head
ok "Database schema ready"

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
        print('yes' if users < 5 or products < 20 else 'no')
asyncio.run(check())
" 2>/dev/null || echo "yes")

if [ "$NEEDS_SEED" = "yes" ]; then
  info "Seeding demo data..."
  python -m scripts.seed
  ok "Demo data seeded"
else
  ok "Database already seeded"
fi

python -m scripts.seed --sync-support
python -m scripts.seed --sync-challenges
ok "Support tickets + challenge metadata synced"

info "Starting uvicorn on 0.0.0.0:${BACKEND_PORT:-8000}..."
exec python -m uvicorn app.main:app \
  --host 0.0.0.0 \
  --port "${BACKEND_PORT:-8000}" \
  --log-level info
