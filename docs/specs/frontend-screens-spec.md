# Flutter Frontend Application Screens & Functionalities Specification

This document provides a comprehensive specification of the frontend mobile application built using **Flutter** and **BLoC/Cubit** state management. It details each user screen, its visual components, state management interactions, form controllers, and service integration.

---

## Architecture & Navigation Overview

The Flutter application follows a modular, feature-driven structure:
* **State Management**: Implemented using `flutter_bloc` (`Cubit` pattern) for predictable state transitions (`AuthCubit`, `UploadVideoCubit`).
* **Secure Persistence**: Employs `flutter_secure_storage` to persist session cookies (`access_token`, `refresh_token`, `user_cognito_sub`).
* **Media & File Handlers**: Utilizes `image_picker` for local file selection, `path_provider` for persistent file copy management, and `better_player` for MPEG-DASH video playback.

```
[ Sign Up Page ]  ──(Success)──>  [ Confirm Sign Up (OTP) ]  ──(Success)──>  [ Sign In Page ]
        │                                                                          │
        └───────────────────────────(Already Have Account)─────────────────────────┘
                                                                                   │
                                                                           (Session Valid / Login)
                                                                                   │
                                                                                   ▼
                                                                           [ Home Feed Page ]
                                                                                   │
                                                          ┌────────────────────────┴────────────────────────┐
                                                          ▼                                                 ▼
                                                [ Upload Video Page ]                             [ Video Player Page ]
```

---

## 1. Sign Up Page (`sign_up_page.dart`)

### Overview
The initial entry screen for unauthenticated users. It allows new users to register their account attributes (`Name`, `Email`, `Password`) with the platform.

### UI Layout & Components
* **Header**: Large bold screen title ("Sign Up").
* **Form Inputs** (`TextFormField`):
  * **Name Field**: Text input bound to `nameController`.
  * **Email Field**: Text input bound to `emailController` with email syntax validation.
  * **Password Field**: Obscured text input bound to `passwordController` (`obscureText: true`).
* **Action Button**: `ElevatedButton` ("Sign Up") triggering form validation and registration dispatch.
* **Navigation Link**: `RichText` / `GestureDetector` ("Already have an account? Sign In") redirecting to the Sign In screen.

### Controllers & Keys
* `GlobalKey<FormState> _formKey`: Form validation handle.
* `TextEditingController nameController`: Name input manager.
* `TextEditingController emailController`: Email input manager.
* `TextEditingController passwordController`: Password input manager.

### Functional Workflow
1. **Form Validation**: User taps "Sign Up". The app calls `_formKey.currentState!.validate()`. If any field is empty or fails validation, an inline `errorBorder` is rendered.
2. **Cubit Dispatch**: Triggers `context.read<AuthCubit>().signUpUser(name, email, password)`.
3. **Backend Communication**: `AuthService.signUpUser()` submits a `POST` request to `/auth/signup`.
4. **State Handling & Navigation**:
   * On `AuthSignUpSuccess`: Displays a `SnackBar` instructing the user to verify their email, and pushes the `ConfirmSignUpPage` onto the navigation stack, passing `emailController.text`.
   * On `AuthError`: Displays a red `SnackBar` containing the exception detail returned by FastAPI/Cognito.

---

## 2. Confirm Sign Up / OTP Verification Page (`confirm_signup_page.dart`)

### Overview
A verification screen where newly registered users enter the One-Time Password (OTP) sent to their email by AWS Cognito to confirm their account.

### UI Layout & Components
* **Header**: Screen title ("Confirm Sign Up").
* **Form Inputs**:
  * **Email Field**: Pre-filled `TextFormField` (read-only or editable) displaying the user's registered email address.
  * **OTP Field**: Obscured numeric text input bound to `otpController` (`obscureText: true`).
* **Action Button**: `ElevatedButton` ("Confirm") submitting the verification code.

### Controllers & Keys
* `TextEditingController emailController`: Holds user email passed from the Sign Up flow.
* `TextEditingController otpController`: OTP input manager.

### Functional Workflow
1. **OTP Submission**: Tapping "Confirm" executes `context.read<AuthCubit>().confirmSignUpUser(email, otp)`.
2. **Backend Communication**: `AuthService.confirmSignUpUser()` posts `{ "email": email, "otp": otp }` to `/auth/confirm-signup`.
3. **State Handling & Navigation**:
   * On `AuthConfirmSignUpSuccess`: Renders a success `SnackBar` ("User confirmed successfully") and redirects the user to the `LoginPage`.
   * On `AuthError`: Renders an error `SnackBar` (e.g., "Invalid verification code").

---

## 3. Sign In / Login Page (`login_page.dart`)

### Overview
The authentication screen for existing users to sign into their account and establish a persistent secure session.

### UI Layout & Components
* **Header**: Title ("Sign In").
* **Form Inputs**:
  * **Email Field**: Text input bound to `emailController`.
  * **Password Field**: Obscured text input bound to `passwordController`.
* **Action Button**: `ElevatedButton` ("Sign In") triggering authentication.
* **Navigation Link**: `RichText` ("Don't have an account? Sign Up") pushing `SignUpPage`.

### Controllers & Keys
* `GlobalKey<FormState> _formKey`: Form key for field validation.
* `TextEditingController emailController`: Email input manager.
* `TextEditingController passwordController`: Password input manager.

### Functional Workflow
1. **Authentication Request**: Tapping "Sign In" calls `context.read<AuthCubit>().loginUser(email, password)`.
2. **Cookie Interception & Persistence**:
   * `AuthService.loginUser()` sends a `POST` request to `/auth/login`.
   * FastAPI responds with `200 OK` and sets `HTTPOnly` cookies (`access_token`, `refresh_token`).
   * The Flutter app parses the `Set-Cookie` header using RegExp patterns:
     ```dart
     RegExp(r'access_token=([^;]+)')
     RegExp(r'refresh_token=([^;]+)')
     ```
   * The extracted tokens are stored securely in OS storage via `FlutterSecureStorage.write()`.
3. **Session Hydration**:
   * The app calls `/auth/me` to retrieve current user attributes (`Cognito sub`, `name`, `email`).
   * Saves `user_cognito_sub` to `FlutterSecureStorage`.
4. **State Transition**:
   * Emits `AuthLoginSuccess`.
   * The top-level `BlocBuilder` in `main.dart` detects `AuthLoginSuccess` and automatically switches the active root widget to `HomePage`.

---

## 4. Home Page (`homepage.dart`)

### Overview
The primary feed screen listing all processed, publicly available videos. It acts as the application dashboard after logging in.

### UI Layout & Components
* **App Bar**:
  * App Title ("Video Stream").
  * Action Icon Button (`+` / `add` icon): Navigates to `UploadPage`.
* **Body Feed**: Rendered using a `FutureBuilder` wrapped around a `ListView.builder`.
* **Video Feed Card Components**:
  * **Thumbnail Image**: `Image.network` displaying the video's thumbnail. Includes custom headers (`x-amz-acl: public-read` or CloudFront CDN host domain) to resolve cross-origin policies.
  * **Video Title**: Bold text displaying the video title (`video['title']`).
  * **Video Metadata**: Visual indicators for video status and channel/owner info.

### Controllers & Services
* `VideoService videoService`: Service class executing backend queries.
* `Future<List<Map<String, dynamic>>> videoFuture`: Cached future holding the fetched video list to prevent unnecessary re-fetches on widget rebuilds.

### Functional Workflow
1. **App Launch Session Handshake**:
   * `main.dart` calls `AuthCubit.isAuthenticated()`.
   * If `access_token` is valid or successfully renewed via `/auth/refresh`, `HomePage` renders automatically.
2. **Feed Fetching**:
   * Calls `VideoService.getVideos()`, making a `GET` request to `/video/all` with stored cookie headers attached.
   * Filters out videos where `is_processing != completed` or `visibility == private`.
3. **User Interactions**:
   * Tapping the `+` action button pushes `UploadPage.route()`.
   * Tapping any video card invokes `Navigator.push(VideoPlayerPage.route(video))`, passing the selected video metadata map.

---

## 5. Upload Video Page (`upload_page.dart`)

### Overview
The content creation screen allowing users to pick a local thumbnail image, select a raw video file, enter video metadata, and trigger the multi-stage direct-to-S3 upload pipeline.

### UI Layout & Components
* **App Bar**: Title ("Upload Page").
* **Interactive Media Pickers**:
  * **Thumbnail Selector**: A custom `DottedBorder` container (`height: 150`, `dashPattern: [10, 4]`). Displays `icons.folder_open` and "Select the thumbnail for your video". When selected, replaces the container with `Image.file(imageFile)` formatted with `BoxFit.cover`.
  * **Video File Selector**: A second `DottedBorder` container displaying `icons.video_file_outlined` and "Select your video file". Replaced by the selected video's filename/path when picked.
* **Metadata Input Fields**:
  * **Title Field**: `TextFormField` for the video title (`titleController`).
  * **Description Field**: Multi-line `TextFormField` (`maxLines: null`) for video description (`descriptionController`).
  * **Visibility Dropdown**: `DropdownButton<String>` with menu options: `public`, `private`, `unlisted`. Defaults to `private`.
* **Action Button**: `ElevatedButton` ("Upload") executing the background pipeline.

### Controllers & Media Pickers
* `TextEditingController titleController`: Video title manager.
* `TextEditingController descriptionController`: Video description manager.
* `File? imageFile`: Holds the picked thumbnail image file.
* `File? videoFile`: Holds the picked raw video file.
* `String visibility`: Tracks dropdown choice (defaults to `'private'`).

### Functional Workflow (The Multi-Stage Upload Pipeline)
When the user taps "Upload", `context.read<UploadVideoCubit>().uploadVideo(...)` executes the following sequence:

```
[ Pick Files ] ──> [ Get S3 Presigned URLs ] ──> [ Copy Files to Perm Path ] ──> [ Direct PUT to S3 ] ──> [ Save Metadata ]
```

1. **Get Presigned URLs**:
   * Calls `UploadVideoService.getPresignedUrlForVideo()` (`GET /upload/video/url`) to obtain a presigned PUT URL and `video_id` (`videos/{user_sub}/{uuid}.mp4`).
   * Calls `UploadVideoService.getPresignedUrlForThumbnail()` (`GET /upload/video/url/thumbnail?thumbnail_id=...`) to obtain a presigned PUT URL for the thumbnail (`thumbnails/{user_sub}/{uuid}`).
2. **Directory & File Preparation**:
   * Uses `path_provider` (`getApplicationDocumentsDirectory()`) to create local persistent file copies matching the S3 Key structure before upload, avoiding OS cache purge errors.
3. **Direct Binary Upload to S3**:
   * Streams raw video bytes (`video/mp4`) directly to S3 via HTTP `PUT`.
   * Streams raw thumbnail bytes (`image/jpg`) directly to the thumbnail S3 bucket via HTTP `PUT` with header `x-amz-acl: public-read`.
4. **Save Metadata to PostgreSQL**:
   * Calls `UploadVideoService.uploadMetadata()` (`POST /upload/video/metadata`), submitting:
     ```json
     {
       "title": "Ronaldo in Waterfall",
       "description": "Video description...",
       "visibility": "public",
       "video_id": "videos/user_sub/uuid.mp4",
       "video_s3_key": "videos/user_sub/uuid.mp4"
     }
     ```
5. **UI Reaction**:
   * Renders `circularProgressIndicator` during processing.
   * On `UploadVideoSuccess`: Displays a green `SnackBar` ("Video uploaded successfully") and pops the screen (`Navigator.pop()`), returning to `HomePage`.
   * On `UploadVideoError`: Displays an error `SnackBar`.

---

## 6. Video Player Page (`video_player_page.dart`)

### Overview
The media playback screen where users stream transcoded videos using adaptive bitrate MPEG-DASH streaming over CloudFront CDN.

### UI Layout & Components
* **Video Player Viewport**: Rendered at the top using the `BetterPlayer` widget constrained to a `16:9` aspect ratio.
* **Player Controls**:
  * Play / Pause toggle overlay.
  * Adaptive progress timeline bar.
  * Quality selector menu (dynamically switching between `360p`, `720p`, `1080p` DASH streams).
  * Playback speed selector (`0.5x`, `1.0x`, `1.5x`, `2.0x`).
  * Fullscreen toggle.
* **Video Detail Panel**:
  * Bold title heading (`widget.video['title']`).
  * Expandable description container (`widget.video['description']`).
  * Channel / Owner details.

### Controllers & Playback Mechanics
* `late BetterPlayerController _betterPlayerController`: Manages stream initialization, buffering, and UI events.

### Functional Workflow
1. **CloudFront CDN Manifest Resolution**:
   * On `initState()`, constructs the streaming manifest URL:
     `https://{cloudfront_domain}/{video_s3_key}/manifest.mpd`
2. **Data Source Configuration**:
   * Configures `BetterPlayerDataSource`:
     ```dart
     BetterPlayerDataSource(
       BetterPlayerDataSourceType.network,
       cloudfrontManifestUrl,
       videoFormat: BetterPlayerVideoFormat.dash,
     )
     ```
3. **Adaptive Streaming Execution**:
   * `BetterPlayer` fetches `manifest.mpd` and continuously requests 6-second `.m4s` video segments from CloudFront.
   * Automatically adapts video resolution (`360p` vs `720p` vs `1080p`) based on client bandwidth conditions.
4. **Lifecycle Management**:
   * On widget disposal (`dispose()`), calls `_betterPlayerController.dispose()` to free media player memory and prevent memory leaks.

---

## Summary Matrix of Frontend Screens

| Screen Name | File Path | Primary Function | Primary Package / Tools |
| :--- | :--- | :--- | :--- |
| **Sign Up** | `lib/pages/auth/sign_up_page.dart` | Account creation | `flutter_bloc`, `TextFormField` |
| **Confirm Sign Up** | `lib/pages/auth/confirm_signup_page.dart` | OTP email verification | `AuthCubit`, AWS Cognito OTP |
| **Sign In** | `lib/pages/auth/login_page.dart` | Authentication & token storage | `flutter_secure_storage`, Cookie RegExp |
| **Home Feed** | `lib/pages/home_page.dart` | Public video feed list | `FutureBuilder`, `ListView.builder`, `VideoService` |
| **Upload Video** | `lib/pages/upload_page.dart` | Video/thumbnail pick & S3 upload | `image_picker`, `dotted_border`, `path_provider` |
| **Video Player** | `lib/pages/video_player_page.dart` | MPEG-DASH adaptive video playback | `better_player`, CloudFront CDN |
