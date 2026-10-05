"""The seed script and the app wired to SQLite, in-process."""

import importlib
import sqlite3

import pytest
from fastapi.testclient import TestClient

from scripts.seed_sqlite import seed_database
from tests.support import seed_data


@pytest.fixture(scope="module")
def client(tmp_path_factory, monkeypatch_module):
    db = tmp_path_factory.mktemp("db") / "sanity.db"
    seed_database(db)
    for line in open("tests/support/test.env"):
        line = line.strip()
        if line and not line.startswith("#"):
            k, v = line.split("=", 1)
            monkeypatch_module.setenv(k, v)
    monkeypatch_module.setenv("DATABASE_URL", f"sqlite:///{db}")

    from app import config, db as app_db
    config.get_settings.cache_clear()
    app_db.get_engine.cache_clear()
    app_db._session_factory.cache_clear()
    import tests.support.server as server
    importlib.reload(server)
    with TestClient(server.app) as c:
        yield c
    app_db.get_engine().dispose()
    config.get_settings.cache_clear()
    app_db.get_engine.cache_clear()
    app_db._session_factory.cache_clear()


@pytest.fixture(scope="module")
def monkeypatch_module():
    mp = pytest.MonkeyPatch()
    yield mp
    mp.undo()


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
    token = r.cookies["access_token"]
    me = client.get("/auth/me", headers={"Authorization": f"Bearer {token}"}).json()
    assert me["id"] == str(seed_data.ALICE.id)
