"""Signed playback cookies: the pure helpers, then expiry through the app."""

import json
from datetime import datetime, timedelta, timezone

import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

from app import media_signing
from app.config import get_settings
from tests.support import seed_data


@pytest.mark.parametrize("keys, folder", [
    (("v1/dash/manifest.mpd", "v1/dash/master.m3u8"), "v1/dash"),
    (("v1/dash/manifest.mpd", None), "v1/dash"),
    ((None, "/v1/hls/master.m3u8"), "v1/hls"),
    (("v1/dash/manifest.mpd", "v1/hls/master.m3u8"), "v1"),
    # Nothing in common, or a key at the bucket root: never the whole bucket.
    (("v1/manifest.mpd", "v2/master.m3u8"), None),
    (("manifest.mpd",), None),
    ((None, None), None),
])
def test_media_folder(keys, folder):
    assert media_signing.media_folder(*keys) == folder


def test_cloudfront_base64_has_no_url_specials():
    data = bytes(range(256))
    text = media_signing.cf_b64encode(data)
    assert not set(text) & set("+=/")
    assert media_signing.cf_b64decode(text) == data


def test_policy_is_compact_json():
    p = media_signing.policy("https://*/v1/dash/*", 1700000000)
    assert p == ('{"Statement":[{"Resource":"https://*/v1/dash/*",'
                 '"Condition":{"DateLessThan":{"AWS:EpochTime":1700000000}}}]}')


@pytest.fixture
def signing_key(monkeypatch):
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = key.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL,
        serialization.NoEncryption(),
    ).decode()
    monkeypatch.setenv("MEDIA_KEY_PAIR_ID", "K1")
    # One line with literal \n, as a .env file holds it.
    monkeypatch.setenv("MEDIA_PRIVATE_KEY", pem.replace("\n", "\\n"))
    monkeypatch.setenv("MEDIA_BASE_URL", "https://edge.example/media/")
    get_settings.cache_clear()
    yield key
    get_settings.cache_clear()


def test_sign_cookies(signing_key):
    now = datetime(2026, 10, 27, 12, tzinfo=timezone.utc)
    signed = media_signing.sign_cookies("v1/dash", now=now)
    assert signed.path == "/media/v1/dash/"
    assert signed.expires_at == now + timedelta(seconds=3600)
    v = signed.values
    assert v[media_signing.KEY_PAIR_COOKIE] == "K1"
    policy = media_signing.cf_b64decode(v[media_signing.POLICY_COOKIE])
    statement = json.loads(policy)["Statement"][0]
    assert statement["Resource"] == "https://*/v1/dash/*"
    assert statement["Condition"]["DateLessThan"]["AWS:EpochTime"] == int(signed.expires_at.timestamp())
    # Verifies with the public key, as CloudFront does (raises if not).
    signing_key.public_key().verify(
        media_signing.cf_b64decode(v[media_signing.SIGNATURE_COOKIE]), policy,
        padding.PKCS1v15(), hashes.SHA1(),
    )


def test_no_key_no_cookies(monkeypatch):
    monkeypatch.setenv("MEDIA_KEY_PAIR_ID", "")
    get_settings.cache_clear()
    try:
        assert media_signing.sign_cookies("v1/dash") is None
    finally:
        get_settings.cache_clear()


def test_playback_cookies_expire(client):
    """Through the app and the test server's /media/ gate, with the key the
    server generated."""
    video = seed_data.VIDEOS_BY_KEY["mountains"]
    url = f"/media/{video.stem}/master.m3u8"
    assert client.post(f"/video/{video.id}/playback").status_code == 200
    assert client.get(url).status_code == 200

    two_hours_ago = datetime.now(timezone.utc) - timedelta(hours=2)
    old = media_signing.sign_cookies(str(video.stem), now=two_hours_ago)
    client.cookies.clear()
    for name, value in old.values.items():
        client.cookies.set(name, value, path=old.path)
    assert client.get(url).status_code == 403


def test_playback_without_a_key(client, monkeypatch):
    monkeypatch.setenv("MEDIA_PRIVATE_KEY", "")
    get_settings.cache_clear()
    try:
        r = client.post(f"/video/{seed_data.VIDEOS_BY_KEY['guitar'].id}/playback")
        assert (r.status_code, r.json()) == (200, {"expires_at": None})
        assert "set-cookie" not in r.headers
    finally:
        monkeypatch.undo()
        get_settings.cache_clear()


EDGE_FUNCTION = "../frontend/terraform/media-viewer-request.js"
_RUN_EDGE_FUNCTION = """
const code = require('fs').readFileSync(process.argv[1], 'utf8');
const handler = new Function(code + '; return handler;')();
const out = JSON.parse(process.argv[2]).map(([uri, qs]) => {
  const querystring = {};
  if (qs) querystring[qs] = {value: ''};
  const r = handler({request: {uri, querystring, headers: {}, cookies: {}}});
  return r.statusCode ? r.statusCode : r.uri;
});
console.log(JSON.stringify(out));
"""

EDGE_CASES = [
    # (path, query, what the function does: a status, or the S3 key path)
    ("/media/v1/dash/master.m3u8", "", "/v1/dash/master.m3u8"),
    ("/media/v1/dash/chunk-0-00001.m4s", "", "/v1/dash/chunk-0-00001.m4s"),
    ("/media/v1/dash/master.m3u8", "v", 400),
    ("/media/v2/dash/master.m3u8", "/v1/dash/x", 400),
    ("/media/v1/../v2/dash/master.m3u8", "", 400),
    ("/media/v1/./dash/master.m3u8", "", 400),
    ("/media/..", "", 400),
    ("/media/v1/dash/x%2F..%2Fy", "", 400),
    ("/media/v1/dash/master m3u8", "", 400),
    ("/media/", "", 400),
]


def test_edge_function_and_its_stand_in_agree(client):
    """Runs the CloudFront Function under node and checks the test server's
    stand-in (tests/support/server.py) refuses the same requests."""
    import shutil
    import subprocess

    import tests.support.server as server

    node = shutil.which("node")
    if node is None:
        pytest.skip("node not installed")
    cases = json.dumps([[p, q] for p, q, _ in EDGE_CASES])
    out = subprocess.run(
        [node, "-e", _RUN_EDGE_FUNCTION, EDGE_FUNCTION, cases],
        check=True, capture_output=True, text=True,
    ).stdout
    assert json.loads(out) == [expected for _, _, expected in EDGE_CASES]
    for path, query, expected in EDGE_CASES:
        assert server.edge_function_allows(path, query) == (expected != 400), path
