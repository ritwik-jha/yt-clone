"""users-table writes shared by signup and the current-user dependency."""

from sqlalchemy import func
from sqlalchemy.dialects import postgresql, sqlite
from sqlalchemy.orm import Session

from app.models import User


def upsert_user(db: Session, *, cognito_sub: str, email: str, name: str) -> User:
    """Create or re-link the profile row for a Cognito user, then commit.

    Cognito guarantees one live account per email, so an existing row with
    the same email belongs to an account that no longer exists (deleted and
    re-registered). Re-pointing it at the new sub keeps that user's videos.
    Two concurrent calls for the same user both land on the same row.
    """
    # SQLite (the test database) has the same ON CONFLICT ... RETURNING.
    insert = sqlite.insert if db.get_bind().dialect.name == "sqlite" else postgresql.insert
    stmt = (
        insert(User)
        .values(cognito_sub=cognito_sub, email=email, name=name)
        .on_conflict_do_update(
            index_elements=[User.email],
            set_={"cognito_sub": cognito_sub, "name": name, "updated_at": func.now()},
        )
        .returning(User)
    )
    user = db.scalars(stmt, execution_options={"populate_existing": True}).one()
    db.commit()
    return user
