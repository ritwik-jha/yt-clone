import os

import httpx
import pytest

LIVE_URL = os.environ.get("API_BASE_URL", "").rstrip("/")


@pytest.fixture(scope="session")
def live_url() -> str:
    if not LIVE_URL:
        pytest.skip("API_BASE_URL not set: start the test server (scripts/run_pipeline.sh)")
    return LIVE_URL


@pytest.fixture
def anon(live_url):
    with httpx.Client(base_url=live_url, timeout=10) as client:
        yield client
