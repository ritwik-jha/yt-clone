import httpx
import pytest

from tests.support import seed_data


def login(live_url: str, email: str, password: str = seed_data.PASSWORD) -> httpx.Client:
    client = httpx.Client(base_url=live_url, timeout=10)
    r = client.post("/auth/login", json={"email": email, "password": password})
    assert r.status_code == 200, r.text
    # Native clients send the token as a Bearer header; do the same.
    client.headers["Authorization"] = f"Bearer {r.cookies['access_token']}"
    client.refresh_token = r.cookies["refresh_token"]
    return client


@pytest.fixture
def alice(live_url):
    client = login(live_url, seed_data.ALICE.email)
    yield client
    client.close()


@pytest.fixture
def bob(live_url):
    client = login(live_url, seed_data.BOB.email)
    yield client
    client.close()
