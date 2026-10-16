import httpx
import pytest

from tests.support import seed_data


def login(live_url: str, email: str, password: str = seed_data.PASSWORD) -> httpx.Client:
    """A client holding the login cookies, the way the browser does: the
    access cookie goes everywhere, the refresh cookie only under /auth."""
    client = httpx.Client(base_url=live_url, timeout=10)
    r = client.post("/auth/login", json={"email": email, "password": password})
    assert r.status_code == 200, r.text
    assert client.cookies.get("access_token")
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
