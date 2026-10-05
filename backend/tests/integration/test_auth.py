"""Auth endpoints against the live server (fake Cognito, SQLite users)."""

import uuid

import httpx

from tests.support import seed_data
from tests.integration.conftest import login


def test_login_sets_http_only_cookies(anon):
    r = anon.post("/auth/login", json={"email": "ALICE@example.com", "password": seed_data.PASSWORD})
    assert r.status_code == 200
    cookies = r.headers.get_list("set-cookie")
    assert any(c.startswith("access_token=") and "HttpOnly" in c and "Path=/" in c for c in cookies)
    assert any(c.startswith("refresh_token=") and "Path=/auth/refresh" in c for c in cookies)


def test_login_failures(anon):
    r = anon.post("/auth/login", json={"email": seed_data.ALICE.email, "password": "Wrong0ne!"})
    assert (r.status_code, r.json()["code"]) == (400, "incorrect_credentials")
    r = anon.post("/auth/login", json={"email": seed_data.CAROL.email, "password": seed_data.PASSWORD})
    assert (r.status_code, r.json()["code"]) == (400, "user_not_confirmed")
    r = anon.post("/auth/login", json={"email": "not-an-email", "password": "x"})
    assert (r.status_code, r.json()["code"]) == (400, "validation_error")


def test_me_requires_a_valid_token(anon, alice):
    assert anon.get("/auth/me").json()["code"] == "missing_access_token"
    r = anon.get("/auth/me", headers={"Authorization": "Bearer nope"})
    assert (r.status_code, r.json()["code"]) == (401, "token_invalid")
    me = alice.get("/auth/me").json()
    assert me == {**me, "id": str(seed_data.ALICE.id), "email": seed_data.ALICE.email,
                  "name": seed_data.ALICE.name, "cognito_sub": seed_data.ALICE.sub}


def test_refresh_then_logout_revokes(live_url):
    client = login(live_url, seed_data.BOB.email)
    refresh = client.refresh_token
    with httpx.Client(base_url=live_url) as raw:
        assert raw.post("/auth/refresh").json()["code"] == "missing_refresh_token"
        r = raw.post("/auth/refresh", headers={"Cookie": f"refresh_token={refresh}"})
        assert r.status_code == 200
        new_access = r.cookies["access_token"]
        assert raw.get("/auth/me", headers={"Authorization": f"Bearer {new_access}"}).status_code == 200

        r = raw.post("/auth/logout", headers={"Cookie": f"refresh_token={refresh}"})
        assert r.status_code == 200
        assert any(c.startswith('access_token=""') or "Max-Age=0" in c for c in r.headers.get_list("set-cookie"))
        r = raw.get("/auth/me", headers={"Authorization": f"Bearer {new_access}"})
        assert (r.status_code, r.json()["code"]) == (401, "token_invalid")
        r = raw.post("/auth/refresh", headers={"Cookie": f"refresh_token={refresh}"})
        assert (r.status_code, r.json()["code"]) == (401, "refresh_token_invalid")


def test_signup_verify_login_and_reset_password(anon, live_url):
    email = f"new-{uuid.uuid4().hex[:8]}@example.com"
    body = {"name": "New Person", "email": email, "password": seed_data.PASSWORD}
    assert anon.post("/auth/signup", json=body).status_code == 200
    r = anon.post("/auth/signup", json=body)
    assert (r.status_code, r.json()["code"]) == (400, "email_exists")
    r = anon.post("/auth/signup", json={**body, "email": "x" + email, "password": "weakpass"})
    assert (r.status_code, r.json()["code"]) == (400, "validation_error")

    r = anon.post("/auth/login", json={"email": email, "password": seed_data.PASSWORD})
    assert r.json()["code"] == "user_not_confirmed"
    assert anon.post("/auth/resend-otp", json={"email": email}).status_code == 200
    r = anon.post("/auth/verify-otp", json={"email": email, "otp": "000000"})
    assert (r.status_code, r.json()["code"]) == (400, "code_mismatch")
    assert anon.post("/auth/verify-otp", json={"email": email, "otp": seed_data.OTP}).status_code == 200

    client = login(live_url, email)
    me = client.get("/auth/me").json()
    client.close()
    assert (me["email"], me["name"]) == (email, "New Person")

    # Unknown emails get the same answer as known ones.
    assert anon.post("/auth/forgot-password", json={"email": "ghost@example.com"}).status_code == 200
    assert anon.post("/auth/forgot-password", json={"email": email}).status_code == 200
    new_password = "N3w-Passw0rd"
    r = anon.post("/auth/reset-password", json={"email": email, "otp": seed_data.OTP, "new_password": new_password})
    assert r.status_code == 200
    login(live_url, email, new_password).close()
