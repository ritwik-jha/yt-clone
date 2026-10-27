"""POST /video/{id}/playback and the signed-cookie gate on /media/.

The test server's /media/ (tests/support/server.py) checks the cookies the
way the edge distribution does, with the public half of the key the API
signs with.
"""

import uuid
from datetime import datetime, timedelta, timezone

import httpx
import pytest

from app import media_signing
from tests.support import seed_data

V = seed_data.VIDEOS_BY_KEY
COOKIES = {media_signing.POLICY_COOKIE, media_signing.SIGNATURE_COOKIE, media_signing.KEY_PAIR_COOKIE}


def _playback(client: httpx.Client, key: str) -> httpx.Response:
    return client.post(f"/video/{V[key].id}/playback")


def _hls(client: httpx.Client, key: str) -> str:
    return client.get(f"/video/{V[key].id}").json()["hls_url"]


def _set_cookie_headers(r: httpx.Response) -> dict[str, str]:
    return {h.split("=", 1)[0]: h for h in r.headers.get_list("set-cookie")}


def test_media_needs_the_cookies(anon, live_url):
    url = _hls(anon, "mountains")
    assert url == f"/media/{V['mountains'].stem}/master.m3u8"
    assert anon.get(url).status_code == 403

    r = _playback(anon, "mountains")
    assert r.status_code == 200, r.text
    assert r.headers["cache-control"] == "no-store"
    expires = datetime.fromisoformat(r.json()["expires_at"])
    left = expires - datetime.now(timezone.utc)
    assert timedelta(minutes=59) < left <= timedelta(hours=1)

    headers = _set_cookie_headers(r)
    assert set(headers) == COOKIES
    for header in headers.values():
        assert f"Path=/media/{V['mountains'].stem}/" in header
        assert "HttpOnly" in header and "Max-Age=3600" in header

    assert anon.get(url).status_code == 200
    # Everything in the folder: segments sit next to the playlists.
    assert anon.get(f"/media/{V['mountains'].stem}/chunk-0-00001.m4s").status_code == 200


def test_cookies_open_only_their_own_video(anon, live_url):
    assert _playback(anon, "mountains").status_code == 200
    other = _hls(anon, "guitar")
    # The browser would not even send them (Path); a client that does is
    # refused by the policy's Resource.
    stolen = {name: anon.cookies.get(name) for name in COOKIES}
    with httpx.Client(base_url=live_url, cookies=stolen, timeout=10) as thief:
        assert thief.get(_hls(anon, "mountains")).status_code == 200
        assert thief.get(other).status_code == 403


def test_query_strings_and_dot_segments_are_refused(anon, live_url):
    """`*` in the policy spans slashes, so the edge refuses what could make
    another video's URL end in this video's folder."""
    assert _playback(anon, "mountains").status_code == 200
    folder = f"/media/{V['mountains'].stem}"
    other = f"/media/{V['guitar'].stem}/master.m3u8"
    assert anon.get(f"{other}?x={folder[len('/media'):]}/a").status_code == 400
    assert anon.get(f"{folder}/master.m3u8?v=1").status_code == 400
    # httpx would normalise "..": send the raw path.
    raw = f"{folder}/../{V['guitar'].stem}/master.m3u8".encode()
    r = anon.send(anon.build_request("GET", "/", extensions={"target": raw}))
    assert r.status_code == 400


def test_tampered_cookies_are_refused(anon, live_url):
    """Expiry is checked in tests/sanity/test_media_signing.py, which can sign
    with the server's key."""
    assert _playback(anon, "mountains").status_code == 200
    url = _hls(anon, "mountains")
    good = {name: anon.cookies.get(name) for name in COOKIES}

    # A wider policy (another folder, a later expiry) under the real signature.
    forged = media_signing.policy(f"https://*/{V['guitar'].stem}/*", 2_000_000_000)
    bad = {**good, media_signing.POLICY_COOKIE: media_signing.cf_b64encode(forged.encode())}
    with httpx.Client(base_url=live_url, cookies=bad, timeout=10) as c:
        assert c.get(f"/media/{V['guitar'].stem}/master.m3u8").status_code == 403

    wrong_key = {**good, media_signing.KEY_PAIR_COOKIE: "K2SOMEOTHERKEY"}
    with httpx.Client(base_url=live_url, cookies=wrong_key, timeout=10) as c:
        assert c.get(url).status_code == 403

    missing = {k: v for k, v in good.items() if k != media_signing.KEY_PAIR_COOKIE}
    with httpx.Client(base_url=live_url, cookies=missing, timeout=10) as c:
        assert c.get(url).status_code == 403


@pytest.mark.parametrize("key, anon_status", [
    ("mountains", 200), ("drafts", 200), ("diary", 404), ("rendering", 404), ("broken", 404),
])
def test_who_may_stream(anon, alice, bob, key, anon_status):
    owner, other = (alice, bob) if V[key].owner == "alice" else (bob, alice)
    assert _playback(anon, key).status_code == anon_status
    assert _playback(other, key).status_code == anon_status
    r = _playback(owner, key)
    if V[key].status == seed_data.VideoStatus.COMPLETED:
        assert r.status_code == 200
        assert owner.get(_hls(owner, key)).status_code == 200
    else:
        # The owner can read it, but there is nothing to stream yet.
        assert (r.status_code, r.json()["code"]) == (409, "video_not_ready")


def test_unknown_video(anon):
    r = anon.post(f"/video/{uuid.uuid4()}/playback")
    assert (r.status_code, r.json()["code"]) == (404, "video_not_found")
