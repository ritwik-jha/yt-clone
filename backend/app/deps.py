"""FastAPI dependencies — resolves the current user from the access cookie
(or Bearer header fallback) by calling Cognito's GetUser."""

from fastapi import Depends, HTTPException, Request, status

from app.clients import cognito


def _extract_token(request: Request) -> str:
    token = request.cookies.get("access_token")
    if token:
        return token
    auth = request.headers.get("Authorization", "")
    if auth.startswith("Bearer "):
        return auth.split(" ", 1)[1]
    raise HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Missing access token",
    )


def get_current_user(request: Request) -> dict:
    token = _extract_token(request)
    try:
        resp = cognito().get_user(AccessToken=token)
    except cognito().exceptions.NotAuthorizedException:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Token invalid or revoked",
        )
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc))

    attrs = {a["Name"]: a["Value"] for a in resp.get("UserAttributes", [])}
    if "sub" not in attrs:
        raise HTTPException(status_code=401, detail="Invalid token payload")
    return {
        "sub":      attrs["sub"],
        "email":    attrs.get("email", ""),
        "name":     attrs.get("name", ""),
        "username": resp.get("Username", ""),
    }


CurrentUser = Depends(get_current_user)
