"""The seed script and the app wired to SQLite, in-process."""

import sqlite3

from scripts.seed_sqlite import seed_database
from tests.support import seed_data


def test_seed_is_deterministic(tmp_path):
    a, b = tmp_path / "a.db", tmp_path / "b.db"
    seed_database(a)
    seed_database(b)
    q = "SELECT id, title, created_at FROM videos ORDER BY id"
    assert sqlite3.connect(a).execute(q).fetchall() == sqlite3.connect(b).execute(q).fetchall()
    assert len(sqlite3.connect(a).execute(q).fetchall()) == len(seed_data.VIDEOS)


def test_health(client):
    assert client.get("/healthz").json() == {"status": "ok"}


def test_feed_reads_seeded_rows(client):
    body = client.get("/video/feed", params={"limit": 50}).json()
    assert body["total"] == len(seed_data.FEED)
    assert [i["id"] for i in body["items"]] == [str(v.id) for v in seed_data.FEED]


def test_login_and_me(client):
    r = client.post("/auth/login", json={"email": seed_data.ALICE.email, "password": seed_data.PASSWORD})
    assert r.status_code == 200
    me = client.get("/auth/me").json()
    assert me["id"] == str(seed_data.ALICE.id)
    # Cookies only: the Authorization header is not an auth path.
    token = client.cookies["access_token"]
    client.cookies.clear()
    r = client.get("/auth/me", headers={"Authorization": f"Bearer {token}"})
    assert (r.status_code, r.json()["code"]) == (401, "missing_access_token")
