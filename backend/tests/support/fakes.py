"""In-process stand-ins for Cognito, S3 and Redis.

The test server (tests/support/server.py) installs them in app.clients, so a
backend running on SQLite needs no AWS account. They implement only the calls
the app makes and fail the way the real services do (botocore ClientError
codes), so the routers' error mapping is exercised too.
"""

import secrets
import threading
import uuid

import fakeredis
from botocore.exceptions import ClientError

from tests.support import seed_data


def _error(code: str, message: str, operation: str) -> ClientError:
    return ClientError({"Error": {"Code": code, "Message": message}}, operation)


class FakeCognito:
    """Accounts start as the seeded users (password seed_data.PASSWORD);
    every confirmation and reset code is seed_data.OTP."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._users: dict[str, dict] = {
            u.email: {"sub": u.sub, "name": u.name, "password": seed_data.PASSWORD,
                      "confirmed": u.confirmed}
            for u in seed_data.USERS
        }
        self._access: dict[str, str] = {}   # token -> email
        self._refresh: dict[str, str] = {}  # token -> email

    def _user(self, email: str, op: str) -> dict:
        user = self._users.get(email)
        if user is None:
            raise _error("UserNotFoundException", "User does not exist.", op)
        return user

    def _check_code(self, code: str, op: str) -> None:
        if code != seed_data.OTP:
            raise _error("CodeMismatchException", "Invalid code provided.", op)

    def sign_up(self, *, Username, Password, UserAttributes, **_):
        with self._lock:
            if Username in self._users:
                raise _error("UsernameExistsException", "User already exists", "SignUp")
            attrs = {a["Name"]: a["Value"] for a in UserAttributes}
            sub = str(uuid.uuid4())
            self._users[Username] = {"sub": sub, "name": attrs.get("name", ""),
                                     "password": Password, "confirmed": False}
        return {"UserSub": sub, "UserConfirmed": False}

    def admin_delete_user(self, *, Username, **_):
        with self._lock:
            self._users.pop(Username, None)

    def confirm_sign_up(self, *, Username, ConfirmationCode, **_):
        with self._lock:
            user = self._user(Username, "ConfirmSignUp")
            self._check_code(ConfirmationCode, "ConfirmSignUp")
            if user["confirmed"]:
                raise _error("NotAuthorizedException", "User cannot be confirmed. Current status is CONFIRMED", "ConfirmSignUp")
            user["confirmed"] = True
        return {}

    def resend_confirmation_code(self, *, Username, **_):
        user = self._user(Username, "ResendConfirmationCode")
        if user["confirmed"]:
            raise _error("InvalidParameterException", "User is already confirmed.", "ResendConfirmationCode")
        return {}

    def forgot_password(self, *, Username, **_):
        self._user(Username, "ForgotPassword")
        return {}

    def confirm_forgot_password(self, *, Username, ConfirmationCode, Password, **_):
        with self._lock:
            user = self._user(Username, "ConfirmForgotPassword")
            self._check_code(ConfirmationCode, "ConfirmForgotPassword")
            user["password"] = Password
        return {}

    def _issue(self, email: str, refresh: str | None = None) -> dict:
        access = "fake-access-" + secrets.token_urlsafe(16)
        self._access[access] = email
        result = {"AccessToken": access, "ExpiresIn": 3600, "TokenType": "Bearer"}
        if refresh is None:
            refresh = "fake-refresh-" + secrets.token_urlsafe(16)
            self._refresh[refresh] = email
            result["RefreshToken"] = refresh
        return {"AuthenticationResult": result}

    def initiate_auth(self, *, AuthParameters, **_):
        email, password = AuthParameters["USERNAME"], AuthParameters["PASSWORD"]
        with self._lock:
            user = self._users.get(email)
            if user is None or user["password"] != password:
                raise _error("NotAuthorizedException", "Incorrect username or password.", "InitiateAuth")
            if not user["confirmed"]:
                raise _error("UserNotConfirmedException", "User is not confirmed.", "InitiateAuth")
            return self._issue(email)

    def get_tokens_from_refresh_token(self, *, RefreshToken, **_):
        with self._lock:
            email = self._refresh.get(RefreshToken)
            if email is None:
                raise _error("NotAuthorizedException", "Invalid Refresh Token", "GetTokensFromRefreshToken")
            return self._issue(email, refresh=RefreshToken)

    def revoke_token(self, *, Token, **_):
        with self._lock:
            email = self._refresh.pop(Token, None)
            if email is not None:
                # Like Cognito: access tokens from this session die with it.
                self._access = {t: e for t, e in self._access.items() if e != email}
        return {}

    def get_user(self, *, AccessToken):
        with self._lock:
            email = self._access.get(AccessToken)
            user = self._users.get(email) if email else None
            if user is None:
                raise _error("NotAuthorizedException", "Access Token has been revoked", "GetUser")
            return {
                "Username": user["sub"],
                "UserAttributes": [
                    {"Name": "sub", "Value": user["sub"]},
                    {"Name": "email", "Value": email},
                    {"Name": "name", "Value": user["name"]},
                ],
            }


class _Paginator:
    def paginate(self, **_):
        return [{"Contents": []}]


class FakeS3:
    """Presigns URLs nobody serves; deletes always succeed."""

    def __init__(self) -> None:
        self.deleted: list[tuple[str, str]] = []

    def generate_presigned_url(self, *, Params, ExpiresIn, **_):
        return f"https://{Params['Bucket']}.s3.test/{Params['Key']}?X-Amz-Expires={ExpiresIn}"

    def delete_object(self, *, Bucket, Key):
        self.deleted.append((Bucket, Key))
        return {}

    def get_paginator(self, _name):
        return _Paginator()

    def delete_objects(self, **_):
        return {"Errors": []}


def fake_redis() -> fakeredis.FakeRedis:
    return fakeredis.FakeRedis(decode_responses=True)
