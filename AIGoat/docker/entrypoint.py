#!/usr/bin/env python3
"""Distroless-friendly backend entrypoint (no shell required)."""
from __future__ import annotations

import asyncio
import os
import sqlite3
import subprocess
import sys


def info(msg: str) -> None:
    print(f"[INFO] {msg}", flush=True)


def ok(msg: str) -> None:
    print(f"[OK]   {msg}", flush=True)


def fail(msg: str) -> None:
    print(f"[ERROR] {msg}", file=sys.stderr, flush=True)
    raise SystemExit(2)


def run(cmd: list[str]) -> None:
    subprocess.run(cmd, check=True)


def validate_env() -> None:
    provider = os.environ.get("LLM_PROVIDER", "nvidia").strip().lower()
    if provider not in {"nvidia", "openai-compatible", "openai_compatible"}:
        fail(f"This workshop image expects LLM_PROVIDER=nvidia (got '{provider}').")
    if not os.environ.get("NVIDIA_API_KEY", "").strip():
        fail("NVIDIA_API_KEY is required.")
    secret = os.environ.get("APP_SECRET_KEY", "").strip()
    if not secret or secret == "aigoat-dev-secret-change-in-production":
        fail("Set a unique APP_SECRET_KEY in docker/.env.")


def db_state(db_file: str) -> str:
    try:
        names = {
            row[0]
            for row in sqlite3.connect(db_file).execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            )
        }
    except Exception:
        return "empty"
    if "alembic_version" in names:
        return "current"
    if "users" in names:
        return "baseline"
    return "empty"


async def needs_seed() -> bool:
    from sqlalchemy import func, select

    from app.core.database import async_session, init_db
    from app.models import Product, User

    await init_db()
    async with async_session() as db:
        users = (await db.execute(select(func.count(User.id)))).scalar() or 0
        products = (await db.execute(select(func.count(Product.id)))).scalar() or 0
    return users < 5 or products < 20


def main() -> None:
    print("", flush=True)
    print("==========================================", flush=True)
    print("   AI Goat -- Docker Backend Starting     ", flush=True)
    print("==========================================", flush=True)
    print("", flush=True)

    validate_env()
    info(f"NVIDIA model: {os.environ.get('NVIDIA_MODEL', 'nvidia/nemotron-3-ultra-550b-a55b')}")

    info("Applying database migrations...")
    db_file = os.environ.get("DB_FILE", "/app/data/aigoat.db")
    os.makedirs(os.path.dirname(db_file) or "/app/data", exist_ok=True)
    if os.path.isfile(db_file) and db_state(db_file) == "baseline":
        info("Pre-Alembic DB detected; stamping 0001 then upgrading.")
        run([sys.executable, "-m", "alembic", "stamp", "0001"])
    run([sys.executable, "-m", "alembic", "upgrade", "head"])
    ok("Database schema ready")

    info("Checking seed data...")
    try:
        seed_needed = asyncio.run(needs_seed())
    except Exception:
        seed_needed = True

    if seed_needed:
        info("Seeding demo data...")
        run([sys.executable, "-m", "scripts.seed"])
        ok("Demo data seeded")
    else:
        ok("Database already seeded")

    run([sys.executable, "-m", "scripts.seed", "--sync-support"])
    run([sys.executable, "-m", "scripts.seed", "--sync-challenges"])
    ok("Support tickets + challenge metadata synced")

    port = os.environ.get("BACKEND_PORT", "8000")
    info(f"Starting uvicorn on 0.0.0.0:{port}...")
    os.execvp(
        sys.executable,
        [
            sys.executable,
            "-m",
            "uvicorn",
            "app.main:app",
            "--host",
            "0.0.0.0",
            "--port",
            port,
            "--log-level",
            "info",
        ],
    )


if __name__ == "__main__":
    main()
