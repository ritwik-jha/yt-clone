# AWS Cognito & FastAPI Authentication Integration Guide

This guide details the end-to-end implementation of the secure, three-tier user authentication system for the YouTube-like video streaming platform. It covers registration with OTP validation, login, HTTPOnly cookie-based session persistence, and silent session restoration on application boot.

---

## 1. System Architecture & Auth Flows

### A. Signup and OTP Verification Flow
The user registration flow leverages AWS Cognito as the identity provider and PostgreSQL as the local operational database.

```
[ Flutter Client ]                      [ FastAPI Backend ]                    [ AWS Cognito ]
        |                                       |                                     |
        |---- 1. POST /signup (email, pass) --->|                                     |
        |                                       |---- 2. Compute HMAC-SHA256 Hash --->|
        |                                       |---- 3. sign_up() ──────────────────>|
        |                                       |                                     |-- (Sends OTP email)
        |                                       |<--- 4. Return UserSub --------------|
        |                                       |---- 5. Save local PostgreSQL record |
        |<--- 6. Return "Needs verification" ---|                                     |
        |                                       |                                     |
        |---- 7. POST /verify-otp (code) ------>|                                     |
        |                                       |---- 8. Compute HMAC-SHA256 Hash --->|
        |                                       |---- 9. confirm_sign_up() ──────────>|
        |                                       |<--- 10. Return confirmation --------|
        |<--- 11. Return "Verification success" -|                                     |
```

### B. Login Flow with HTTPOnly Cookies
Upon logging in, the backend securely signs request payload signatures and acts as a gateway proxy, receiving access and refresh tokens and returning them as secure HTTPOnly cookies.

```
[ Flutter Client ]                      [ FastAPI Backend ]                    [ AWS Cognito ]
        |                                       |                                     |
        |---- 1. POST /login (email, pass) ---->|                                     |
        |                                       |---- 2. Compute HMAC-SHA256 Hash --->|
        |                                       |---- 3. initiate_auth() ------------>|
        |                                       |<--- 4. Return Access & Refresh -----|
        |                                       |---- 5. Map cookies to response      |
        |<--- 6. Response with Set-Cookie ------|                                     |
        |                                       |                                     |
        |-- 7. Extract cookies via RegExp       |                                     |
        |-- 8. Save tokens to SecureStorage     |                                     |
```

### C. Session Validation on App Launch (The `/me` API)
Whenever the application is restarted, the Flutter app performs a silent handshake to restore the user session.

```
[ Flutter Client ]                      [ FastAPI Backend ]                    [ AWS Cognito ]
        |                                       |                                     |
        |-- 1. Read tokens from SecureStorage   |                                     |
        |---- 2. GET /me (Cookie: access_token) ->|                                     |
        |                                       |---- 3. Extract token from cookie    |
        |                                       |---- 4. get_user() ─────────────────>|
        |                                       |<--- 5. Return user attributes ------|
        |                                       |---- 6. Query DB (Postgres) by Sub   |
        |<--- 7. Return complete user profile --|                                     |
```

---

## 2. Backend (FastAPI) Implementation

### A. Database Layer & PostgreSQL Models
The operational Postgres database mirrors the Cognito accounts using the unique `cognito_sub` string. This acts as the foreign key bridge for video metadata ownership.

```python
# db/models.py
from sqlalchemy import Column, Integer, String, Boolean, DateTime, Enum, ForeignKey
from sqlalchemy.orm import relationship, declarative_base
import enum
from datetime import datetime

Base = declarative_base()

class VideoVisibility(str, enum.Enum):
    PUBLIC = "public"
    PRIVATE = "private"
    UNLISTED = "unlisted"

class VideoProcessingStatus(str, enum.Enum):
    PENDING = "pending"
    PROCESSING = "processing"
    COMPLETED = "completed"
    FAILED = "failed"

class User(Base):
    __tablename__ = "users"

    id = Column(Integer, primary_key=True, index=True)
    name = Column(String, nullable=False)
    email = Column(String, unique=True, index=True, nullable=False)
    cognito_sub = Column(String, unique=True, index=True, nullable=False)  # Map to Cognito Sub
    created_at = Column(DateTime, default=datetime.utcnow)

    # Relationships
    videos = relationship("Video", back_populates="uploader", cascade="all, delete-orphan")

class Video(Base):
    __tablename__ = "videos"

    id = Column(String, primary_key=True, index=True)  # UUID string generated by backend
    title = Column(String, nullable=False)
    description = Column(String, nullable=True)
    raw_video_url = Column(String, nullable=False)  # S3 bucket raw file location
    processed_video_url = Column(String, nullable=True)  # S3 processed DASH manifest location
    thumbnail_url = Column(String, nullable=True)
    duration = Column(Integer, nullable=True)  # duration in seconds
    visibility = Column(Enum(VideoVisibility), default=VideoVisibility.PUBLIC)
    status = Column(Enum(VideoProcessingStatus), default=VideoProcessingStatus.PENDING)
    uploader_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow)

    # Relationships
    uploader = relationship("User", back_populates="videos")
```

### B. Request and Response Pydantic Schemas
```python
# schemas/auth_schemas.py
from pydantic import BaseModel, EmailStr, Field
from typing import Optional
from datetime import datetime

class SignUpRequest(BaseModel):
    name: str = Field(..., min_length=2, max_length=50)
    email: EmailStr
    password: str = Field(..., min_length=8)

class VerifyOTPRequest(BaseModel):
    email: EmailStr
    otp_code: str = Field(..., min_length=6, max_length=6)

class LoginRequest(BaseModel):
    email: EmailStr
    password: str

class UserProfileResponse(BaseModel):
    id: int
    name: str
    email: EmailStr
    cognito_sub: str
    created_at: datetime

    class Config:
        from_attributes = True
```

### C. Cryptographic Helper Core
Cognito App Clients with secrets enforce signature verification. Standard hashing is vulnerable to **length-extension attacks**, so we employ an **HMAC-SHA256 signature** that hashes in two nested rounds to break any mathematical hash state chaining.

```python
# helper/crypto_helper.py
import hmac
import hashlib
import base64

def get_secret_hash(username: str, client_id: str, client_secret: str) -> str:
    """
    Computes secure HMAC-SHA256 signature required by AWS Cognito client calls.
    Protects client-side signatures against length-extension compromises.
    """
    message = username + client_id
    key = client_secret.encode('utf-8')
    
    # Nested double-pass hashing
    hmac_digest = hmac.new(
        key,
        message.encode('utf-8'),
        digestmod=hashlib.sha256
    ).digest()
    
    return base64.b64encode(hmac_digest).decode()
```

### D. Authentication API Endpoints
The backend acts as the gateway to Cognito. It parses secure cookies (`access_token`, `refresh_token`) to insulate the client.

```python
# routers/auth_router.py
from fastapi import APIRouter, Depends, HTTPException, Response, Request, status
from sqlalchemy.orm import Session
import boto3
import os

from db.db import get_db
from db.models import User
from schemas.auth_schemas import SignUpRequest, VerifyOTPRequest, LoginRequest, UserProfileResponse
from helper.crypto_helper import get_secret_hash

router = APIRouter(prefix="/auth", tags=["Authentication"])

# SQS, Cognito, S3 variables extracted from OS env or config files
COGNITO_CLIENT_ID = os.getenv("COGNITO_CLIENT_ID", "your_client_id")
COGNITO_CLIENT_SECRET = os.getenv("COGNITO_CLIENT_SECRET", "your_client_secret")
AWS_REGION = os.getenv("AWS_REGION", "ap-south-1")

cognito_client = boto3.client("cognito-idp", region_name=AWS_REGION)

@router.post("/signup", status_code=status.HTTP_201_CREATED)
def signup(data: SignUpRequest, db: Session = Depends(get_db)):
    try:
        # 1. Compute HMAC signature
        secret_hash = get_secret_hash(data.email, COGNITO_CLIENT_ID, COGNITO_CLIENT_SECRET)
        
        # 2. Invoke Cognito User registration
        response = cognito_client.sign_up(
            ClientId=COGNITO_CLIENT_ID,
            Username=data.email,
            Password=data.password,
            UserAttributes=[
                {"Name": "email", "Value": data.email},
                {"Name": "name", "Value": data.name}
            ],
            SecretHash=secret_hash
        )
        
        # 3. Mirror User metadata record in Postgres database immediately
        cognito_sub = response.get("UserSub")
        new_user = User(name=data.name, email=data.email, cognito_sub=cognito_sub)
        
        db.add(new_user)
        db.commit()
        db.refresh(new_user)
        
        return {
            "message": "Registration successful. Please check your email for the verification OTP.",
            "cognito_sub": cognito_sub
        }
    except cognito_client.exceptions.UsernameExistsException:
        raise HTTPException(status_code=400, detail="An account with this email already exists.")
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.post("/verify-otp")
def verify_otp(data: VerifyOTPRequest):
    try:
        secret_hash = get_secret_hash(data.email, COGNITO_CLIENT_ID, COGNITO_CLIENT_SECRET)
        
        # Call Cognito confirm registration API
        cognito_client.confirm_sign_up(
            ClientId=COGNITO_CLIENT_ID,
            Username=data.email,
            ConfirmationCode=data.otp_code,
            SecretHash=secret_hash
        )
        return {"message": "Account verified successfully. You can now log in."}
    except cognito_client.exceptions.CodeMismatchException:
        raise HTTPException(status_code=400, detail="Invalid OTP code provided. Please try again.")
    except cognito_client.exceptions.ExpiredCodeException:
        raise HTTPException(status_code=400, detail="The verification code has expired.")
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.post("/login")
def login(data: LoginRequest, response: Response):
    try:
        secret_hash = get_secret_hash(data.email, COGNITO_CLIENT_ID, COGNITO_CLIENT_SECRET)
        
        # Sign-in payload verification
        cognito_response = cognito_client.initiate_auth(
            ClientId=COGNITO_CLIENT_ID,
            AuthFlow="USER_PASSWORD_AUTH",
            AuthParameters={
                "USERNAME": data.email,
                "PASSWORD": data.password,
                "SECRET_HASH": secret_hash
            }
        )
        
        auth_result = cognito_response.get("AuthenticationResult")
        access_token = auth_result.get("AccessToken")
        refresh_token = auth_result.get("RefreshToken")
        
        # Prevent javascript injection vulnerabilities (XSS protection)
        response.set_cookie(
            key="access_token",
            value=access_token,
            httponly=True,
            secure=True,  # Set to True in production (HTTPS required)
            samesite="lax",
            max_age=3600  # 1 hour
        )
        response.set_cookie(
            key="refresh_token",
            value=refresh_token,
            httponly=True,
            secure=True,
            samesite="lax",
            max_age=432000  # 5 days
        )
        
        return {"message": "Login successful"}
    except cognito_client.exceptions.UserNotConfirmedException:
        raise HTTPException(status_code=403, detail="Your account is not verified yet. Please verify OTP first.")
    except cognito_client.exceptions.NotAuthorizedException:
        raise HTTPException(status_code=401, detail="Incorrect email or password.")
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.get("/me", response_model=UserProfileResponse)
def get_me(request: Request, db: Session = Depends(get_db)):
    # 1. Read the access token from secure cookies
    access_token = request.cookies.get("access_token")
    if not access_token:
        # Fallback helper for client Authorization headers
        auth_header = request.headers.get("Authorization")
        if auth_header and auth_header.startswith("Bearer "):
            access_token = auth_header.split(" ")[1]
            
    if not access_token:
        raise HTTPException(status_code=401, detail="Authentication credentials missing.")
        
    try:
        # 2. Verify token validity directly against AWS Cognito User Directory
        cognito_user = cognito_client.get_user(AccessToken=access_token)
        
        # 3. Extract the unique User Sub ID from cognito attributes
        cognito_sub = None
        for attr in cognito_user.get("UserAttributes", []):
            if attr["Name"] == "sub":
                cognito_sub = attr["Value"]
                break
                
        if not cognito_sub:
            raise HTTPException(status_code=401, detail="Invalid token properties.")
            
        # 4. Fetch mirrored user record from PostgreSQL
        user_record = db.query(User).filter(User.cognito_sub == cognito_sub).first()
        if not user_record:
            raise HTTPException(status_code=404, detail="User record not synchronized in databases.")
            
        return user_record
    except cognito_client.exceptions.NotAuthorizedException:
        raise HTTPException(status_code=401, detail="Token signature expired or revoked.")
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))
```

---

## 3. Frontend (Flutter) Implementation

### A. Core Authentication API Service
This service encapsulates HTTP calls, handles cross-platform host IP configurations (replacing `localhost` with physical host IPs for emulators), parses HTTP Headers to isolate `Set-Cookie` strings, and persists credentials using secure OS storage.

```dart
// services/auth_service.dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AuthService {
  // Replace with local network machine IP for physical test devices / emulators
  final String baseUrl = "http://192.168.1.10:8000/auth";
  final _secureStorage = const FlutterSecureStorage();

  // Create registration request
  Future<void> signUp({
    required String name,
    required String email,
    required String password,
  }) async {
    final response = await http.post(
      Uri.parse("$baseUrl/signup"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({
        "name": name,
        "email": email,
        "password": password,
      }),
    );

    if (response.statusCode != 201) {
      final error = jsonDecode(response.body)['detail'] ?? "Signup failed";
      throw Exception(error);
    }
  }

  // Confirm verification code
  Future<void> verifyOtp({
    required String email,
    required String otpCode,
  }) async {
    final response = await http.post(
      Uri.parse("$baseUrl/verify-otp"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({
        "email": email,
        "otp_code": otpCode,
      }),
    );

    if (response.statusCode != 200) {
      final error = jsonDecode(response.body)['detail'] ?? "Verification failed";
      throw Exception(error);
    }
  }

  // Handle Login and manually parse Cookie headers for iOS/Android storage
  Future<void> login({
    required String email,
    required String password,
  }) async {
    final response = await http.post(
      Uri.parse("$baseUrl/login"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({
        "email": email,
        "password": password,
      }),
    );

    if (response.statusCode == 200) {
      await _extractAndSaveCookies(response);
    } else {
      final error = jsonDecode(response.body)['detail'] ?? "Login failed";
      throw Exception(error);
    }
  }

  // Retrieve user session from /me Endpoint
  Future<Map<String, dynamic>> validateSession() async {
    final String? accessToken = await _secureStorage.read(key: "access_token");
    if (accessToken == null) {
      throw Exception("No access token cached locally.");
    }

    final response = await http.get(
      Uri.parse("$baseUrl/me"),
      headers: {
        "Content-Type": "application/json",
        // Pass Access Token in Authorization Header as fallback for mobile HTTP systems
        "Authorization": "Bearer $accessToken",
        // Set cookie header matching FastAPI's expectations
        "Cookie": "access_token=$accessToken"
      },
    );

    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      await clearTokens();
      throw Exception("Session invalid. Re-authentication required.");
    }
  }

  // Extract Cookie values using RegExp
  Future<void> _extractAndSaveCookies(http.Response response) async {
    final String? setCookieHeader = response.headers['set-cookie'];
    if (setCookieHeader != null) {
      final RegExp accessTokenRegExp = RegExp(r'access_token=([^;]+)');
      final RegExp refreshTokenRegExp = RegExp(r'refresh_token=([^;]+)');

      final Match? accessMatch = accessTokenRegExp.firstMatch(setCookieHeader);
      final Match? refreshMatch = refreshTokenRegExp.firstMatch(setCookieHeader);

      if (accessMatch != null) {
        await _secureStorage.write(key: "access_token", value: accessMatch.group(1));
      }
      if (refreshMatch != null) {
        await _secureStorage.write(key: "refresh_token", value: refreshMatch.group(1));
      }
    }
  }

  // Clean tokens on sign out
  Future<void> clearTokens() async {
    await _secureStorage.delete(key: "access_token");
    await _secureStorage.delete(key: "refresh_token");
  }
}
```

### B. App BLoC / Cubit Authentication Orchestration
The app UI reads this State machine to navigate users globally between screens (Authentication Feed vs App Feed).

```dart
// cubit/auth_cubit.dart
import 'package:flutter_bloc/flutter_bloc.dart';
import '../services/auth_service.dart';

// Authentication State Definitions
abstract class AuthState {}

class AuthInitial extends AuthState {}
class AuthLoading extends AuthState {}
class AuthAuthenticated extends AuthState {
  final Map<String, dynamic> userProfile;
  AuthAuthenticated({required this.userProfile});
}
class AuthUnauthenticated extends AuthState {}
class AuthNeedsVerification extends AuthState {
  final String email;
  AuthNeedsVerification({required this.email});
}
class AuthError extends AuthState {
  final String errorMessage;
  AuthError({required this.errorMessage});
}

// State Machine Cubit
class AuthCubit extends Cubit<AuthState> {
  final AuthService _authService = AuthService();

  AuthCubit() : super(AuthInitial());

  // Silent session restore executed in main.dart on app init
  Future<void> initializeAppSession() async {
    emit(AuthLoading());
    try {
      final userProfile = await _authService.validateSession();
      emit(AuthAuthenticated(userProfile: userProfile));
    } catch (_) {
      emit(AuthUnauthenticated());
    }
  }

  // Execute registration
  Future<void> registerNewUser({
    required String name,
    required String email,
    required String password,
  }) async {
    emit(AuthLoading());
    try {
      await _authService.signUp(name: name, email: email, password: password);
      emit(AuthNeedsVerification(email: email));
    } catch (e) {
      emit(AuthError(errorMessage: e.toString()));
    }
  }

  // Execute OTP confirmation
  Future<void> confirmUserOtp({
    required String email,
    required String otpCode,
  }) async {
    emit(AuthLoading());
    try {
      await _authService.verifyOtp(email: email, otpCode: otpCode);
      emit(AuthUnauthenticated()); // Route to login page after successful verification
    } catch (e) {
      emit(AuthError(errorMessage: e.toString()));
    }
  }

  // Execute User login
  Future<void> loginUser({
    required String email,
    required String password,
  }) async {
    emit(AuthLoading());
    try {
      await _authService.login(email: email, password: password);
      final userProfile = await _authService.validateSession();
      emit(AuthAuthenticated(userProfile: userProfile));
    } catch (e) {
      emit(AuthError(errorMessage: e.toString()));
    }
  }

  // Logout session
  Future<void> logoutUser() async {
    emit(AuthLoading());
    await _authService.clearTokens();
    emit(AuthUnauthenticated());
  }
}
```
