"""Create a fresh SQLite test database and fill it with the seed records.

    python scripts/seed_sqlite.py                 # ./test.db
    python scripts/seed_sqlite.py --db /tmp/x.db

The schema comes from the ORM models (the Alembic revisions are written for
PostgreSQL). The records are tests/support/seed_data.py, so every run gives
the same ids, timestamps and counts.
"""

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from sqlalchemy import create_engine, func, select  # noqa: E402
from sqlalchemy.orm import Session  # noqa: E402

from app.models import Base, User, Video  # noqa: E402
from tests.support import seed_data as seed  # noqa: E402


def seed_database(path: Path) -> dict[str, int]:
    for suffix in ("", "-journal", "-wal", "-shm"):
        Path(f"{path}{suffix}").unlink(missing_ok=True)
    engine = create_engine(f"sqlite:///{path}")
    Base.metadata.create_all(engine)
    with Session(engine) as db:
        for u in seed.USERS:
            db.add(User(id=u.id, name=u.name, email=u.email, cognito_sub=u.sub,
                        created_at=seed._EPOCH, updated_at=seed._EPOCH))
        for v in seed.VIDEOS:
            completed = v.status.value == "COMPLETED"
            db.add(Video(
                id=v.id,
                title=v.title,
                description=f"Seeded test video '{v.key}'.",
                s3_key=seed.s3_key(v),
                thumbnail_s3_key=seed.thumbnail_key(v),
                dash_manifest_s3_key=f"{v.stem}/manifest.mpd" if completed else None,
                hls_manifest_s3_key=f"{v.stem}/master.m3u8" if completed else None,
                visibility=v.visibility,
                status=v.status,
                user_id=seed.USERS_BY_KEY[v.owner].id,
                views_count=v.views,
                duration_seconds=v.duration,
                created_at=v.created_at,
                updated_at=v.created_at,
            ))
        db.commit()
        counts = {
            "users": db.scalar(select(func.count()).select_from(User)),
            "videos": db.scalar(select(func.count()).select_from(Video)),
        }
    engine.dispose()
    return counts


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--db", type=Path, default=ROOT / "test.db")
    args = parser.parse_args()
    counts = seed_database(args.db.resolve())
    print(f"seeded {args.db}: {counts['users']} users, {counts['videos']} videos")


if __name__ == "__main__":
    main()
