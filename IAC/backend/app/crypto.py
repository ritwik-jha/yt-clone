"""HMAC-SHA256 secret hash required by Cognito app clients with a secret."""

import base64
import hashlib
import hmac


def secret_hash(username: str, client_id: str, client_secret: str) -> str:
    message = (username + client_id).encode("utf-8")
    key = client_secret.encode("utf-8")
    digest = hmac.new(key, message, digestmod=hashlib.sha256).digest()
    return base64.b64encode(digest).decode()
