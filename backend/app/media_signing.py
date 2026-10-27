"""CloudFront signed cookies for the playback media.

The edge distribution (frontend/terraform/cloudfront.tf) serves the
processed bucket under /media/ and refuses any request without a valid
signature from the key group the API holds the private key of. POST
/video/{id}/playback calls `sign_cookies` for the folder holding the video's
manifests and segments; the browser then sends the three cookies with every
manifest and segment request under that folder.

Why cookies rather than signed URLs: players fetch segments by URLs relative
to the manifest, so a signature in the manifest's query string never reaches
them.

The policy's Resource is `https://*/<folder>/*`. The host is a wildcard
because the API sits behind nginx and the distribution and never learns the
domain the viewer used. A wildcard matches across `/` too, so the edge
function rejects query strings and dot segments on /media/ (otherwise
`/media/<other>/x?/<folder>/` would match); what remains can only reach keys
that contain `/<folder>/` after another video's prefix, and the transcoder
writes none.
"""

import base64
import json
import posixpath
from dataclasses import dataclass
from datetime import datetime, timezone
from functools import lru_cache
from urllib.parse import urlsplit

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

from app.config import get_settings

POLICY_COOKIE = "CloudFront-Policy"
SIGNATURE_COOKIE = "CloudFront-Signature"
KEY_PAIR_COOKIE = "CloudFront-Key-Pair-Id"

# CloudFront's URL-safe base64: '+' '=' '/' become '-' '_' '~'.
_TO_CF = str.maketrans("+=/", "-_~")
_FROM_CF = str.maketrans("-_~", "+=/")


def cf_b64encode(data: bytes) -> str:
    return base64.b64encode(data).decode().translate(_TO_CF)


def cf_b64decode(text: str) -> bytes:
    return base64.b64decode(text.translate(_FROM_CF))


@dataclass(frozen=True)
class SignedCookies:
    values: dict[str, str]
    # Cookie path: the media folder under MEDIA_BASE_URL, so cookies for
    # different videos (other tabs) live side by side.
    path: str
    expires_at: datetime


def signing_enabled() -> bool:
    s = get_settings()
    return bool(s.media_key_pair_id and s.media_private_key)


def media_folder(*keys: str | None) -> str | None:
    """The deepest folder holding every one of the video's media keys, e.g.
    `<video_id>/dash` for `<video_id>/dash/manifest.mpd` and
    `<video_id>/dash/master.m3u8`. None when there is no key, or the keys
    share no folder (signing the whole bucket is never right)."""
    parents = [posixpath.dirname(k.strip("/")) for k in keys if k]
    if not parents:
        return None
    folder = posixpath.commonpath(parents)
    return folder or None


def policy(resource: str, expires_epoch: int) -> str:
    """A custom policy, serialised without whitespace as CloudFront expects."""
    return json.dumps(
        {"Statement": [{
            "Resource": resource,
            "Condition": {"DateLessThan": {"AWS:EpochTime": expires_epoch}},
        }]},
        separators=(",", ":"),
    )


def cookie_path(folder: str) -> str:
    base = urlsplit(get_settings().media_base_url).path.rstrip("/")
    return f"{base}/{folder}/"


@lru_cache
def _private_key(pem: str) -> rsa.RSAPrivateKey:
    # A .env file can hold the PEM on one line with literal \n.
    key = serialization.load_pem_private_key(pem.replace("\\n", "\n").encode(), password=None)
    if not isinstance(key, rsa.RSAPrivateKey):
        raise RuntimeError("MEDIA_PRIVATE_KEY must be an RSA key (CloudFront key groups)")
    return key


def sign(policy_json: str) -> str:
    """RSA-SHA1 over the policy, as CloudFront verifies it."""
    key = _private_key(get_settings().media_private_key)
    return cf_b64encode(key.sign(policy_json.encode(), padding.PKCS1v15(), hashes.SHA1()))


def sign_cookies(folder: str, now: datetime | None = None) -> SignedCookies | None:
    """Cookies that open `folder` (and everything under it) until
    MEDIA_COOKIE_TTL_SECONDS from now. None when the API has no key (local
    runs against unsigned media)."""
    if not signing_enabled():
        return None
    s = get_settings()
    now = now or datetime.now(timezone.utc)
    expires = int(now.timestamp()) + s.media_cookie_ttl_seconds
    policy_json = policy(f"https://*/{folder}/*", expires)
    return SignedCookies(
        values={
            POLICY_COOKIE: cf_b64encode(policy_json.encode()),
            SIGNATURE_COOKIE: sign(policy_json),
            KEY_PAIR_COOKIE: s.media_key_pair_id,
        },
        path=cookie_path(folder),
        expires_at=datetime.fromtimestamp(expires, timezone.utc),
    )
