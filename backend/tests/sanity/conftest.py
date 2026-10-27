"""The app in-process on a fresh seeded SQLite file, one per test module."""

import importlib

import pytest
from fastapi.testclient import TestClient

from scripts.seed_sqlite import seed_database


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
        c.db_path = db
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
