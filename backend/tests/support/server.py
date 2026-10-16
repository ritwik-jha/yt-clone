"""ASGI entrypoint for tests: the real app on SQLite with fake AWS clients.

    DATABASE_URL=sqlite:///./test.db uvicorn tests.support.server:app

Env defaults come from tests/support/test.env (scripts/run_pipeline.sh loads
it). The fakes are installed in app.clients before app.main is imported,
because the routers bind the client functions at import time.

Paths under /_s3/ are a stand-in for the S3 buckets: FakeS3 presigns PUT URLs
there when FAKE_S3_URL points at this server, so a browser can upload the
way it would to S3 (cross-origin, Content-Type checked against the
signature). Everything else is the real API.
"""

import hashlib
import os
from functools import lru_cache

from starlette.applications import Starlette
from starlette.middleware import Middleware
from starlette.middleware.cors import CORSMiddleware
from starlette.requests import Request
from starlette.responses import Response
from starlette.routing import Route

from tests.support import fakes

if not os.environ.get("DATABASE_URL", "").startswith("sqlite"):
    raise RuntimeError("the test server only runs on SQLite (set DATABASE_URL=sqlite:///...)")

import app.clients as clients  # noqa: E402

clients.cognito = lru_cache(fakes.FakeCognito)
clients.s3 = lru_cache(fakes.FakeS3)
clients.redis_client = lru_cache(fakes.fake_redis)

from app.main import app as api  # noqa: E402

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


async def app(scope, receive, send):
    path = scope.get("path", "")
    if scope["type"] == "http" and path.startswith("/_s3/"):
        await _s3({**scope, "path": path[len("/_s3"):]}, receive, send)
    else:
        await api(scope, receive, send)
