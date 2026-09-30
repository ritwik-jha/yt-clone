"""FastAPI dependencies — resolve the caller from the access cookie (or a
Bearer header fallback) by calling Cognito's GetUser, and map them to their
users row.

GetUser rejects expired and revoked tokens, so a logout (RevokeToken) takes
effect on the next request without a local token blacklist.
"""

import logging
from dataclasses import dataclass
from typing import Optional

from botocore.exceptions import BotoCoreError, ClientError
from fastapi import Depends, Request, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.clients import cognito
from app.db import get_db
from app.errors import APIError
from app.models import User
from app.users import upsert_user

log = logging.getLogger(__name__)

ACCESS_COOKIE = "access_token"


@dataclass(frozen=True)
class Identity:
    sub: str
    email: str
    name: str


def _unauthorized(code: str, detail: str) -> APIError:
    return APIError(status.HTTP_401_UNAUTHORIZED, code, detail)


def _idp_unavailable() -> APIError:
    return APIError(503, "identity_provider_unavailable", "Identity provider unavailable")


def _extract_token(request: Request) -> Optional[str]:
    token = request.cookies.get(ACCESS_COOKIE)
    if token:
        return token
    auth = request.headers.get("Authorization", "")
    if auth.startswith("Bearer "):
        return auth.split(" ", 1)[1].strip() or None
    return None


def _identity_from_token(token: str) -> Identity:
    try:
        resp = cognito().get_user(AccessToken=token)
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code in ("NotAuthorizedException", "UserNotFoundException"):
            raise _unauthorized("token_invalid", "Token invalid or revoked") from None
        log.error("Cognito GetUser failed: %s", code)
        raise _idp_unavailable() from None
    except BotoCoreError as exc:
        log.error("Cognito GetUser failed: %s", type(exc).__name__)
        raise _idp_unavailable() from None

    attrs = {a["Name"]: a["Value"] for a in resp.get("UserAttributes", [])}
    if "sub" not in attrs:
        raise _unauthorized("invalid_token_payload", "Invalid token payload")
    return Identity(
        sub=attrs["sub"],
        email=attrs.get("email", "").lower(),
        name=attrs.get("name", ""),
    )


def get_identity(request: Request) -> Identity:
    token = _extract_token(request)
    if not token:
        raise _unauthorized("missing_access_token", "Missing access token")
    return _identity_from_token(token)


def get_optional_identity(request: Request) -> Optional[Identity]:
    """None for anonymous callers; a token that is present but invalid is
    still a 401 so the client knows to refresh."""
    token = _extract_token(request)
    return _identity_from_token(token) if token else None


def get_current_user(
    identity: Identity = Depends(get_identity),
    db: Session = Depends(get_db),
) -> User:
    user = db.scalar(select(User).where(User.cognito_sub == identity.sub))
    if user is not None:
        return user
    # Signup writes this row, but a confirmed Cognito account whose row was
    # lost (failed insert, restored database) should still work: mirror it
    # on first authenticated use.
    log.info("creating missing users row for an authenticated Cognito user")
    return upsert_user(
        db,
        cognito_sub=identity.sub,
        email=identity.email,
        name=identity.name or identity.email,
    )
