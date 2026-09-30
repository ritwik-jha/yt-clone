"""FastAPI application entrypoint.

Run for local dev:
    alembic upgrade head && uvicorn app.main:app --reload

Production (ECS Express Mode service, see backend/terraform/ecs.tf) applies
migrations, then:
    uvicorn app.main:app --host 0.0.0.0 --port 8000 --workers 2 --proxy-headers
"""

import logging

from fastapi import FastAPI, Request
from fastapi.encoders import jsonable_encoder
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from sqlalchemy.exc import OperationalError
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.config import get_settings
from app.routers import auth, upload, video

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
log = logging.getLogger(__name__)

settings = get_settings()
settings.require(
    "cognito_user_pool_id", "cognito_client_id", "cognito_client_secret",
    "s3_raw_videos_bucket", "s3_thumbnails_bucket", "s3_processed_bucket",
    "redis_host", "cloudfront_domain", "thumbnails_cdn_domain",
)
settings.require_database()

app = FastAPI(title="Video Platform Backend", version="2.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origin_list or ["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# Every error body carries a stable `code` next to `detail` (app/errors.py).
# Errors raised by the routing layer rather than a handler get a generic one.
_DEFAULT_CODES = {404: "not_found", 405: "method_not_allowed"}


@app.exception_handler(StarletteHTTPException)
async def http_error(request: Request, exc: StarletteHTTPException):
    code = getattr(exc, "code", None) or _DEFAULT_CODES.get(exc.status_code, "error")
    return JSONResponse(
        status_code=exc.status_code,
        content={"detail": exc.detail, "code": code},
        headers=getattr(exc, "headers", None),
    )


# The API spec reports malformed input as 400, not FastAPI's default 422.
@app.exception_handler(RequestValidationError)
async def validation_error_as_400(request: Request, exc: RequestValidationError):
    return JSONResponse(
        status_code=400,
        content={"detail": jsonable_encoder(exc.errors()), "code": "validation_error"},
    )


@app.exception_handler(OperationalError)
async def database_unavailable(request: Request, exc: OperationalError):
    log.error("database unavailable: %s", type(exc.orig).__name__)
    return JSONResponse(
        status_code=503,
        content={"detail": "Database unavailable", "code": "database_unavailable"},
    )


app.include_router(auth.router)
app.include_router(upload.router)
app.include_router(video.router)


@app.get("/healthz", tags=["meta"])
def health():
    return {"status": "ok"}
