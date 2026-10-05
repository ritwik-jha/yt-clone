"""ASGI entrypoint for tests: the real app on SQLite with fake AWS clients.

    DATABASE_URL=sqlite:///./test.db uvicorn tests.support.server:app

Env defaults come from tests/support/test.env (scripts/run_pipeline.sh loads
it). The fakes are installed in app.clients before app.main is imported,
because the routers bind the client functions at import time.
"""

import os
from functools import lru_cache

from tests.support import fakes

if not os.environ.get("DATABASE_URL", "").startswith("sqlite"):
    raise RuntimeError("the test server only runs on SQLite (set DATABASE_URL=sqlite:///...)")

import app.clients as clients  # noqa: E402

clients.cognito = lru_cache(fakes.FakeCognito)
clients.s3 = lru_cache(fakes.FakeS3)
clients.redis_client = lru_cache(fakes.fake_redis)

from app.main import app  # noqa: E402,F401

