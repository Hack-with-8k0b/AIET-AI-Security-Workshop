from __future__ import annotations

from typing import AsyncGenerator

from sqlalchemy import event
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import declarative_base

from app.core.config import get_settings

Base = declarative_base()

_settings = get_settings()
_db_url = _settings.database.url
_is_sqlite = _db_url.startswith("sqlite")

# SQLite needs longer busy waits under concurrent FastAPI requests. Agent runs
# also hold the session across LLM calls; WAL lets readers proceed while a
# writer is active instead of raising "database is locked" immediately.
_connect_args: dict = {}
if _is_sqlite:
    _connect_args["timeout"] = 30

engine = create_async_engine(
    _db_url,
    echo=False,
    connect_args=_connect_args,
)


if _is_sqlite:

    @event.listens_for(engine.sync_engine, "connect")
    def _sqlite_on_connect(dbapi_connection, connection_record) -> None:  # noqa: ARG001
        cursor = dbapi_connection.cursor()
        cursor.execute("PRAGMA journal_mode=WAL")
        cursor.execute("PRAGMA busy_timeout=30000")
        cursor.execute("PRAGMA synchronous=NORMAL")
        cursor.close()


async_session = async_sessionmaker(
    engine,
    class_=AsyncSession,
    expire_on_commit=False,
    autocommit=False,
    autoflush=False,
)


async def get_db() -> AsyncGenerator[AsyncSession, None]:
    async with async_session() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise
        finally:
            await session.close()


async def init_db() -> None:
    """Create missing tables from SQLAlchemy metadata.

    Kept for tests (`tests/conftest.py` builds an in-memory schema with
    ``create_all``) and for Alembic-less fresh bootstraps. Production schema
    changes go through ``alembic upgrade head``; do not add columns here and
    expect existing databases to pick them up.
    """
    import app.models as _models  # noqa: F401 — register models with Base.metadata
    assert _models
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
