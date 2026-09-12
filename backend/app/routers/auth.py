"""Auth routes — Cognito wrapper + DynamoDB user mirror."""

from datetime import datetime, timezone
from fastapi import APIRouter, Depends, HTTPException, Response, status

from app.clients import cognito, users_table
from app.config import get_settings
from app.crypto import secret_hash
from app.deps import get_current_user
from app.schemas import (
    LoginRequest, SignUpRequest, UserProfileResponse, VerifyOTPRequest,
)

router = APIRouter(prefix="/auth", tags=["auth"])


def _hash(email: str) -> str:
    s = get_settings()
    return secret_hash(email, s.cognito_client_id, s.cognito_client_secret)


@router.post("/signup", status_code=status.HTTP_201_CREATED)
def signup(data: SignUpRequest):
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
    except cognito().exceptions.UsernameExistsException:
        raise HTTPException(status_code=400, detail="Account already exists")
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc))

    sub = resp.get("UserSub")

    users_table().put_item(
        Item={
            "cognito_sub": sub,
            "name":        data.name,
            "email":       data.email,
            "created_at":  datetime.now(timezone.utc).isoformat(),
        },
        ConditionExpression="attribute_not_exists(cognito_sub)",
    )

    return {
        "message":     "Registration successful. Check email for OTP.",
        "cognito_sub": sub,
    }


@router.post("/verify-otp")
def verify_otp(data: VerifyOTPRequest):
    s = get_settings()
    try:
        cognito().confirm_sign_up(
            ClientId=s.cognito_client_id,
            Username=data.email,
            ConfirmationCode=data.otp_code,
            SecretHash=_hash(data.email),
        )
    except cognito().exceptions.CodeMismatchException:
        raise HTTPException(status_code=400, detail="Invalid OTP")
    except cognito().exceptions.ExpiredCodeException:
        raise HTTPException(status_code=400, detail="OTP expired")
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    return {"message": "Verified. You can log in now."}


@router.post("/login")
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
    except cognito().exceptions.UserNotConfirmedException:
        raise HTTPException(status_code=403, detail="Account not verified")
    except cognito().exceptions.NotAuthorizedException:
        raise HTTPException(status_code=401, detail="Incorrect email or password")
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc))

    result = auth["AuthenticationResult"]
    for name, value, max_age in (
        ("access_token",  result["AccessToken"],  s.access_cookie_max_age),
        ("refresh_token", result["RefreshToken"], s.refresh_cookie_max_age),
    ):
        response.set_cookie(
            key=name, value=value,
            httponly=True,
            secure=s.cookie_secure,
            samesite=s.cookie_samesite,
            max_age=max_age,
        )
    return {"message": "Login successful"}


@router.post("/logout")
def logout(response: Response):
    for name in ("access_token", "refresh_token"):
        response.delete_cookie(name)
    return {"message": "Logged out"}


@router.get("/me", response_model=UserProfileResponse)
def get_me(user=Depends(get_current_user)):
    row = users_table().get_item(Key={"cognito_sub": user["sub"]}).get("Item")
    if not row:
        raise HTTPException(status_code=404, detail="User profile not found")
    return UserProfileResponse(
        cognito_sub=row["cognito_sub"],
        name=row["name"],
        email=row["email"],
        created_at=row["created_at"],
    )
