"""Alembic environment.

Every API task runs `alembic upgrade head` before it starts serving, so
several tasks can reach this at once during a deploy or scale-out. A
transaction-scoped advisory lock serialises them: the first applies the
pending revisions, the rest wait, then find the database already at head.
"""

from logging.config import fileConfig

from alembic import context
from sqlalchemy import text

from app.db import get_engine
from app.models import Base

config = context.config
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

target_metadata = Base.metadata

# Any constant works, as long as every migrator uses the same one.
MIGRATION_LOCK_ID = 7_210_531


def run_migrations_offline() -> None:
    """Render SQL (`alembic upgrade head --sql`) without a database."""
    context.configure(
        dialect_name="postgresql",
        target_metadata=target_metadata,
        literal_binds=True,
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    with get_engine().connect() as connection:
        context.configure(connection=connection, target_metadata=target_metadata)
        with context.begin_transaction():
            connection.execute(
                text("SELECT pg_advisory_xact_lock(:id)"), {"id": MIGRATION_LOCK_ID},
            )
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
