import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'auth_interceptor.dart';
import 'config.dart';

/// The two Dio instances the services use.
///
/// The session lives in HttpOnly cookies that the browser stores and sends
/// itself (`withCredentials`), so the app never sees or handles a token.
class ApiClient {
  ApiClient._(this.api, this.bare);

  /// Every API call; refreshes the session once on a 401 and retries.
  final Dio api;

  /// `/auth/refresh`, `/auth/logout`, and the retry after a refresh.
  final Dio bare;

  factory ApiClient({
    required String baseUrl,
    required void Function() onSessionExpired,
  }) {
    BaseOptions options() => BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
      headers: {Headers.acceptHeader: 'application/json'},
      // Cross-origin API calls carry the auth cookies. Same-origin ones
      // carry them anyway.
      extra: {'withCredentials': true},
    );

    final bare = Dio(options());
    final api = Dio(options())
      ..interceptors.add(AuthInterceptor(bare, onSessionExpired));
    if (kDebugMode && AppConfig.httpLogs) {
      // Bodies stay off: they would include passwords.
      api.interceptors.add(
        LogInterceptor(
          requestHeader: false,
          requestBody: false,
          responseHeader: false,
          responseBody: false,
        ),
      );
    }
    return ApiClient._(api, bare);
  }
}
