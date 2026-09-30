"""Auth routes — Cognito wrapper + PostgreSQL users mirror.

Tokens travel only in HttpOnly cookies and are never logged. The refresh
cookie is scoped to Path=/auth/refresh, so a browser sends it nowhere else;
native clients that attach cookies themselves also send it to /auth/logout,
which revokes it.
"""

import logging
from typing import NoReturn, Optional

from botocore.exceptions import BotoCoreError, ClientError
from fastapi import APIRouter, Depends, Request, Response
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from app.clients import cognito
from app.config import get_settings
from app.crypto import secret_hash
from app.db import get_db
from app.deps import ACCESS_COOKIE, get_current_user
from app.errors import APIError
from app.models import User
from app.schemas import (
    EmailRequest, LoginRequest, MessageResponse, ResetPasswordRequest,
    SignUpRequest, UserProfileResponse, VerifyOTPRequest,
)
from app.users import upsert_user

log = logging.getLogger(__name__)

router = APIRouter(prefix="/auth", tags=["auth"])

REFRESH_COOKIE = "refresh_token"
REFRESH_PATH = "/auth/refresh"

_THROTTLED = {
    "TooManyRequestsException",
    "TooManyFailedAttemptsException",
    "LimitExceededException",
}


def _hash(email: str) -> str:
    s = get_settings()
    return secret_hash(email, s.cognito_client_id, s.cognito_client_secret)


# Shared entries for the `known` maps below.
_INVALID_PARAMETER = {"InvalidParameterException": (400, "invalid_parameter", None)}
_CODE_DELIVERY = {
    "CodeDeliveryFailureException": (503, "code_delivery_failed", "Could not send the code, try again later"),
}


def _raise_cognito(
    operation: str, exc: Exception, known: dict[str, tuple[int, str, Optional[str]]],
) -> NoReturn:
    """Map a Cognito failure to an APIError. `known` maps a Cognito error code
    to (status, API code, detail); a None detail passes Cognito's own message
    through (it is written for end users)."""
    error = exc.response.get("Error", {}) if isinstance(exc, ClientError) else {}
    cognito_code = error.get("Code", type(exc).__name__)
    if cognito_code in known:
        status_code, code, detail = known[cognito_code]
        raise APIError(status_code, code, detail or error.get("Message", cognito_code)) from None
    if cognito_code in _THROTTLED:
        raise APIError(429, "too_many_attempts", "Too many attempts, try again later") from None
    log.error("Cognito %s failed: %s", operation, cognito_code)
    raise APIError(500, "identity_provider_error", "Identity provider error") from None


def _set_cookie(response: Response, name: str, value: str, max_age: int, path: str) -> None:
    s = get_settings()
    response.set_cookie(
        key=name, value=value, max_age=max_age, path=path,
        httponly=True, secure=s.cookie_secure, samesite=s.cookie_samesite,
    )


def _clear_cookie(response: Response, name: str, path: str) -> None:
    s = get_settings()
    response.delete_cookie(
        key=name, path=path,
        httponly=True, secure=s.cookie_secure, samesite=s.cookie_samesite,
    )


@router.post("/signup", response_model=MessageResponse)
def signup(data: SignUpRequest, db: Session = Depends(get_db)):
    s = get_settings()
    try:
        resp = cognito().sign_up(
            ClientId=s.cognito_client_id,
            Username=data.email,
            Password=data.password,
            UserAttributes=[
                {"Name": "email", "Value": data.email},
                {"Name": "name",  "Value": data.name},
            ],
            SecretHash=_hash(data.email),
        )
    except (ClientError, BotoCoreError) as exc:
        _raise_cognito("SignUp", exc, {
            "UsernameExistsException":  (400, "email_exists", "An account with this email already exists"),
            "InvalidPasswordException": (400, "invalid_password", None),
            **_INVALID_PARAMETER,
            **_CODE_DELIVERY,
        })

    try:
        upsert_user(db, cognito_sub=resp["UserSub"], email=data.email, name=data.name)
    except SQLAlchemyError:
        db.rollback()
        log.exception("users row insert failed after Cognito SignUp")
        # Undo the Cognito account so the user can simply sign up again.
        # If this fails too, get_current_user recreates the row once the
        # account is confirmed and used.
        try:
            cognito().admin_delete_user(UserPoolId=s.cognito_user_pool_id, Username=data.email)
        except (ClientError, BotoCoreError) as exc:
            log.error("rollback AdminDeleteUser failed: %s", type(exc).__name__)
        raise APIError(500, "profile_create_failed", "Could not create the user profile, please try again") from None

    return MessageResponse(message="Registration successful. Check your email for the verification code.")


@router.post("/verify-otp", response_model=MessageResponse)
def verify_otp(data: VerifyOTPRequest):
    s = get_settings()
    try:
        cognito().confirm_sign_up(
            ClientId=s.cognito_client_id,
            Username=data.email,
            ConfirmationCode=data.otp,
            SecretHash=_hash(data.email),
        )
    except (ClientError, BotoCoreError) as exc:
        _raise_cognito("ConfirmSignUp", exc, {
            "CodeMismatchException":  (400, "code_mismatch", "Invalid verification code"),
            "ExpiredCodeException":   (400, "code_expired", "Verification code expired"),
            "NotAuthorizedException": (400, "not_authorized", None),  # e.g. already confirmed
            "UserNotFoundException":  (404, "user_not_found", "User not found"),
            **_INVALID_PARAMETER,
        })
    return MessageResponse(message="Account verified. You can log in now.")


@router.post("/resend-otp", response_model=MessageResponse)
def resend_otp(data: EmailRequest):
    s = get_settings()
    try:
        cognito().resend_confirmation_code(
            ClientId=s.cognito_client_id,
            Username=data.email,
            SecretHash=_hash(data.email),
        )
    except (ClientError, BotoCoreError) as exc:
        # Cognito's own limit on resends surfaces as LimitExceeded (429).
        _raise_cognito("ResendConfirmationCode", exc, {
            "UserNotFoundException": (404, "user_not_found", "User not found"),
            **_INVALID_PARAMETER,  # e.g. already confirmed
            **_CODE_DELIVERY,
        })
    return MessageResponse(message="Verification code sent. Check your email.")


@router.post("/forgot-password", response_model=MessageResponse)
def forgot_password(data: EmailRequest):
    s = get_settings()
    try:
        cognito().forgot_password(
            ClientId=s.cognito_client_id,
            Username=data.email,
            SecretHash=_hash(data.email),
        )
    except ClientError as exc:
        # The same answer whether or not the account exists, so this route
        # cannot be used to probe for registered emails.
        if exc.response.get("Error", {}).get("Code") != "UserNotFoundException":
            _raise_cognito("ForgotPassword", exc, {
                "NotAuthorizedException": (400, "not_authorized", None),
                **_INVALID_PARAMETER,  # e.g. the email was never verified
                **_CODE_DELIVERY,
            })
    except BotoCoreError as exc:
        _raise_cognito("ForgotPassword", exc, {})
    return MessageResponse(message="If an account exists for this email, a reset code has been sent.")


@router.post("/reset-password", response_model=MessageResponse)
def reset_password(data: ResetPasswordRequest):
    s = get_settings()
    try:
        cognito().confirm_forgot_password(
            ClientId=s.cognito_client_id,
            Username=data.email,
            ConfirmationCode=data.otp,
            Password=data.new_password,
            SecretHash=_hash(data.email),
        )
    except (ClientError, BotoCoreError) as exc:
        _raise_cognito("ConfirmForgotPassword", exc, {
            "CodeMismatchException":    (400, "code_mismatch", "Invalid verification code"),
            "ExpiredCodeException":     (400, "code_expired", "Verification code expired"),
            "InvalidPasswordException": (400, "invalid_password", None),
            "NotAuthorizedException":   (400, "not_authorized", None),
            # Reported like a wrong code so the route does not reveal which
            # emails are registered.
            "UserNotFoundException":    (400, "code_mismatch", "Invalid verification code"),
            **_INVALID_PARAMETER,
        })
    return MessageResponse(message="Password reset. You can log in now.")


@router.post("/login", response_model=MessageResponse)
def login(data: LoginRequest, response: Response):
    s = get_settings()
    try:
        auth = cognito().initiate_auth(
            ClientId=s.cognito_client_id,
            AuthFlow="USER_PASSWORD_AUTH",
            AuthParameters={
                "USERNAME":    data.email,
                "PASSWORD":    data.password,
                "SECRET_HASH": _hash(data.email),
            },
        )
    except (ClientError, BotoCoreError) as exc:
        # With prevent_user_existence_errors on the app client, Cognito
        # reports an unknown email as NotAuthorized, so 404 is rare.
        _raise_cognito("InitiateAuth", exc, {
            "NotAuthorizedException":         (400, "incorrect_credentials", "Incorrect email or password"),
            "UserNotConfirmedException":      (400, "user_not_confirmed", "Account not verified"),
            "PasswordResetRequiredException": (400, "password_reset_required", "Password reset required"),
            "UserNotFoundException":          (404, "user_not_found", "Account does not exist"),
        })

    result = auth.get("AuthenticationResult")
    if not result:
        raise APIError(
            400, "unsupported_challenge",
            f"Unsupported sign-in challenge: {auth.get('ChallengeName', 'unknown')}",
        )

    _set_cookie(response, ACCESS_COOKIE, result["AccessToken"], s.access_cookie_max_age, "/")
    _set_cookie(response, REFRESH_COOKIE, result["RefreshToken"], s.refresh_cookie_max_age, REFRESH_PATH)
    return MessageResponse(message="Login successful")


@router.post("/refresh", response_model=MessageResponse)
def refresh(request: Request, response: Response):
    token = request.cookies.get(REFRESH_COOKIE)
    if not token:
        raise APIError(401, "missing_refresh_token", "Missing refresh token")

    s = get_settings()
    try:
        # Takes the client secret directly, so no SECRET_HASH — which for
        # email-username pools would need the user's sub, not their email.
        resp = cognito().get_tokens_from_refresh_token(
            RefreshToken=token,
            ClientId=s.cognito_client_id,
            ClientSecret=s.cognito_client_secret,
        )
    except (ClientError, BotoCoreError) as exc:
        invalid = (401, "refresh_token_invalid", "Refresh token expired or revoked")
        _raise_cognito("GetTokensFromRefreshToken", exc, {
            "NotAuthorizedException":     invalid,
            "RefreshTokenReuseException": invalid,
            "UserNotFoundException":      invalid,
        })

    result = resp["AuthenticationResult"]
    _set_cookie(response, ACCESS_COOKIE, result["AccessToken"], s.access_cookie_max_age, "/")
    # Present only when refresh token rotation is enabled on the app client.
    if result.get("RefreshToken"):
        _set_cookie(response, REFRESH_COOKIE, result["RefreshToken"], s.refresh_cookie_max_age, REFRESH_PATH)
    return MessageResponse(message="Session refreshed")


@router.post("/logout", response_model=MessageResponse)
def logout(request: Request, response: Response):
    token = request.cookies.get(REFRESH_COOKIE)
    if token:
        s = get_settings()
        try:
            # Also invalidates the access tokens issued from this refresh
            # token, which GetUser then rejects.
            cognito().revoke_token(
                Token=token,
                ClientId=s.cognito_client_id,
                ClientSecret=s.cognito_client_secret,
            )
        except ClientError as exc:
            log.warning("RevokeToken failed: %s", exc.response.get("Error", {}).get("Code"))
        except BotoCoreError as exc:
            log.warning("RevokeToken failed: %s", type(exc).__name__)

    _clear_cookie(response, ACCESS_COOKIE, "/")
    _clear_cookie(response, REFRESH_COOKIE, REFRESH_PATH)
    return MessageResponse(message="Logged out")


@router.get("/me", response_model=UserProfileResponse)
def get_me(user: User = Depends(get_current_user)):
    return user
