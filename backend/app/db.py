"""SQLAlchemy engine and session wiring.

On ECS the database password is never in the task environment. RDS manages
the master password in Secrets Manager and rotates it, so the app fetches it
when it opens a connection (DB_SECRET_ARN) and refetches once if the server
rejects it. Pooled connections survive a rotation; only new ones need the new
password. Local runs set DB_PASSWORD instead.
"""

import json
import logging
from collections.abc import Iterator
from functools import lru_cache

import psycopg
from sqlalchemy import URL, Engine, create_engine, event
from sqlalchemy.orm import Session, sessionmaker

from app.clients import secretsmanager
from app.config import get_settings

log = logging.getLogger(__name__)


@lru_cache
def _secret_password() -> str:
    resp = secretsmanager().get_secret_value(SecretId=get_settings().db_secret_arn)
    return json.loads(resp["SecretString"])["password"]


def _password_rejected(exc: psycopg.OperationalError) -> bool:
    return exc.sqlstate == "28P01" or "password authentication failed" in str(exc)


def _connect_with_secret(dialect, conn_rec, cargs, cparams):
    cparams["password"] = _secret_password()
    try:
        return dialect.connect(*cargs, **cparams)
    except psycopg.OperationalError as exc:
        if not _password_rejected(exc):
            raise
    log.info("database rejected the cached password; refetching the secret")
    _secret_password.cache_clear()
    cparams["password"] = _secret_password()
    return dialect.connect(*cargs, **cparams)


@lru_cache
def get_engine() -> Engine:
    s = get_settings()
    s.require_database()
    engine = create_engine(
        URL.create(
            "postgresql+psycopg",
            username=s.db_user,
            password=s.db_password or None,
            host=s.db_host,
            port=s.db_port,
            database=s.db_name,
        ),
        pool_size=s.db_pool_size,
        max_overflow=s.db_max_overflow,
        pool_pre_ping=True,
        pool_recycle=1800,
        connect_args={"sslmode": s.db_sslmode, "connect_timeout": 5},
    )
    if not s.db_password:
        event.listen(engine, "do_connect", _connect_with_secret)
    return engine


@lru_cache
def _session_factory() -> sessionmaker[Session]:
    return sessionmaker(bind=get_engine(), expire_on_commit=False)


def new_session() -> Session:
    return _session_factory()()


def get_db() -> Iterator[Session]:
    """FastAPI dependency: one session per request, closed afterwards."""
    with new_session() as session:
        yield session
