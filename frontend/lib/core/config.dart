import 'package:flutter/foundation.dart';

class AppConfig {
  /// Compile-time default (`--dart-define-from-file=env/dev.json`). May be
  /// empty in dev builds, where the URL can be entered in the app instead.
  static const apiBaseUrl = String.fromEnvironment('API_BASE_URL');

  /// Lets the backend URL be typed into the app and changed at runtime.
  /// On by default in debug builds only; release builds use `API_BASE_URL`
  /// and nothing else. Force with `--dart-define=ALLOW_SERVER_OVERRIDE=true`.
  static const allowServerOverride = bool.fromEnvironment(
    'ALLOW_SERVER_OVERRIDE',
    defaultValue: kDebugMode,
  );

  static const maxUploadBytes = int.fromEnvironment(
    'MAX_UPLOAD_BYTES',
    defaultValue: 2147483648,
  ); // 2 GiB
  static const httpLogs = bool.fromEnvironment('HTTP_LOGS');
}
