"""ASGI entrypoint for tests: the real app on SQLite with fake AWS clients.

    DATABASE_URL=sqlite:///./test.db uvicorn tests.support.server:app

Env defaults come from tests/support/test.env (scripts/run_pipeline.sh loads
it). The fakes are installed in app.clients before app.main is imported,
because the routers bind the client functions at import time.

Paths under /_s3/ are a stand-in for the S3 buckets: FakeS3 presigns PUT URLs
there when FAKE_S3_URL points at this server, so a browser can upload the
way it would to S3 (cross-origin, Content-Type checked against the
signature).

Paths under /media/ are a stand-in for the edge distribution's media
behaviour (frontend/terraform/cloudfront.tf): the edge function's checks,
then CloudFront's signed-cookie check against a key generated here, which
the API signs with. A request that passes gets the object PUT to the
processed bucket under /_s3/ if there is one, else a small text body naming
the key (seeded videos have no files).
Everything else is the real API.
"""

import hashlib
import json
import os
import re
import time
from functools import lru_cache

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

from starlette.applications import Starlette
from starlette.middleware import Middleware
from starlette.middleware.cors import CORSMiddleware
from starlette.requests import Request
from starlette.responses import Response
from starlette.routing import Route

from tests.support import fakes

if not os.environ.get("DATABASE_URL", "").startswith("sqlite"):
    raise RuntimeError("the test server only runs on SQLite (set DATABASE_URL=sqlite:///...)")

# The API signs playback cookies with this key; /media/ checks them with
# its public half, as CloudFront does with the key group's public key.
MEDIA_KEY_PAIR_ID = "K2TESTKEYPAIR"
_media_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
os.environ["MEDIA_KEY_PAIR_ID"] = MEDIA_KEY_PAIR_ID
os.environ["MEDIA_PRIVATE_KEY"] = _media_key.private_bytes(
    serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption(),
).decode()

import app.clients as clients  # noqa: E402

clients.cognito = lru_cache(fakes.FakeCognito)
clients.s3 = lru_cache(fakes.FakeS3)
clients.redis_client = lru_cache(fakes.fake_redis)

from app.main import app as api  # noqa: E402
from app.media_signing import (  # noqa: E402
    KEY_PAIR_COOKIE, POLICY_COOKIE, SIGNATURE_COOKIE, cf_b64decode,
)

# (bucket, key) -> (content type, body)
OBJECTS: dict[tuple[str, str], tuple[str, bytes]] = {}


async def _put_object(request: Request) -> Response:
    bucket, key = request.path_params["bucket"], request.path_params["key"]
    signed = request.query_params.get("X-Amz-Content-Type", "")
    if request.headers.get("content-type", "") != signed:
        return Response("SignatureDoesNotMatch", status_code=403)
    body = await request.body()
    OBJECTS[(bucket, key)] = (signed, body)
    return Response(status_code=200, headers={"ETag": f'"{hashlib.md5(body).hexdigest()}"'})


async def _head_object(request: Request) -> Response:
    """Lets tests check what arrived: size and type, no body."""
    found = OBJECTS.get((request.path_params["bucket"], request.path_params["key"]))
    if found is None:
        return Response(status_code=404)
    content_type, body = found
    return Response(headers={"Content-Type": content_type, "X-Size": str(len(body))})


_s3 = Starlette(
    routes=[
        Route("/{bucket}/{key:path}", _put_object, methods=["PUT"]),
        Route("/{bucket}/{key:path}", _head_object, methods=["GET"]),
    ],
    # S3 bucket CORS (IAC/terraform/storage.tf): any origin may PUT.
    middleware=[Middleware(
        CORSMiddleware, allow_origins=["*"], allow_methods=["PUT", "GET"],
        allow_headers=["*"], expose_headers=["ETag", "X-Size"],
    )],
)


def _resource_matches(resource: str, url: str) -> bool:
    """CloudFront policy wildcards: `*` is any run of characters (slashes
    too), `?` exactly one."""
    pattern = re.escape(resource).replace(r"\*", ".*").replace(r"\?", ".")
    return re.fullmatch(pattern, url, flags=re.DOTALL) is not None


_MEDIA_PATH = re.compile(r"/media/[A-Za-z0-9._\-/]+")
_DOT_SEGMENT = re.compile(r"(^|/)\.\.?(/|$)")


def edge_function_allows(path: str, query: str) -> bool:
    """What frontend/terraform/media-viewer-request.js lets through."""
    return not query and bool(_MEDIA_PATH.fullmatch(path)) and not _DOT_SEGMENT.search(path)


def _cookie_allows(request: Request, url: str) -> bool:
    cookies = request.cookies
    try:
        policy = cf_b64decode(cookies[POLICY_COOKIE])
        signature = cf_b64decode(cookies[SIGNATURE_COOKIE])
        if cookies[KEY_PAIR_COOKIE] != MEDIA_KEY_PAIR_ID:
            return False
        _media_key.public_key().verify(signature, policy, padding.PKCS1v15(), hashes.SHA1())
        statement = json.loads(policy)["Statement"][0]
        expires = statement["Condition"]["DateLessThan"]["AWS:EpochTime"]
    except (KeyError, IndexError, ValueError, TypeError, InvalidSignature):
        return False
    return time.time() < expires and _resource_matches(statement["Resource"], url)


# Media requests seen, newest last: (path, status). Tests read it through
# GET /_cdn/log to check what the player fetched.
MEDIA_LOG: list[tuple[str, int]] = []


async def _media(request: Request) -> Response:
    path = request.url.path
    # The edge function (frontend/terraform/media-viewer-request.js).
    if not edge_function_allows(path, request.url.query):
        status = 400
    # Behind CloudFront every URL the policy sees is https.
    elif not _cookie_allows(request, f"https://{request.url.netloc}{path}"):
        status = 403
    else:
        status = 200
    MEDIA_LOG.append((path, status))
    if status != 200:
        return Response(status_code=status)
    key = path[len("/media/"):]
    stored = OBJECTS.get((os.environ.get("S3_PROCESSED_BUCKET", ""), key))
    if stored is not None:
        content_type, body = stored
        return Response(body, media_type=content_type)
    return Response(f"media {key}\n", media_type="text/plain")


async def _media_log(request: Request) -> Response:
    return Response(json.dumps(MEDIA_LOG), media_type="application/json")


_cdn = Starlette(
    routes=[
        Route("/media/{key:path}", _media, methods=["GET", "HEAD"]),
        Route("/_cdn/log", _media_log, methods=["GET"]),
    ],
    # The web app on another port (scripts/run_pipeline.sh) streams with
    # credentials. In production the app and media share one origin.
    middleware=[Middleware(
        CORSMiddleware,
        allow_origins=[o for o in os.environ.get("CORS_ORIGINS", "").split(",") if o],
        allow_credentials=True, allow_methods=["GET", "HEAD"],
    )],
)


async def app(scope, receive, send):
    path = scope.get("path", "")
    if scope["type"] == "http" and path.startswith("/_s3/"):
        await _s3({**scope, "path": path[len("/_s3"):]}, receive, send)
    elif scope["type"] == "http" and (path.startswith("/media/") or path == "/_cdn/log"):
        await _cdn(scope, receive, send)
    else:
        await api(scope, receive, send)
