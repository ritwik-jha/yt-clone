import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'auth_interceptor.dart';
import 'config.dart';
import 'cookie_capture.dart';
import 'token_store.dart';

/// The three Dio instances from plan §5.4.
class ApiClient {
  ApiClient._(this.api, this.bare, this.s3);

  /// Every API call; Bearer header + single-flight refresh.
  final Dio api;

  /// `/auth/refresh`, `/auth/logout`, and the retry after a refresh.
  final Dio bare;

  /// Presigned S3 PUTs. Never carries an Authorization header.
  final Dio s3;

  factory ApiClient({
    required TokenStore tokens,
    required void Function() onSessionExpired,
    String? baseUrl,
  }) {
    final url = baseUrl ?? AppConfig.apiBaseUrl;
    BaseOptions apiOptions() => BaseOptions(
      baseUrl: url,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
      headers: {Headers.acceptHeader: 'application/json'},
    );

    final bare = Dio(apiOptions())..interceptors.add(CookieCapture(tokens));
    final api = Dio(apiOptions())
      ..interceptors.addAll([
        CookieCapture(tokens),
        AuthInterceptor(tokens, bare, onSessionExpired),
      ]);
    if (kDebugMode && AppConfig.httpLogs) {
      // Headers and bodies stay off: they would leak tokens and passwords.
      api.interceptors.add(
        LogInterceptor(
          requestHeader: false,
          requestBody: false,
          responseHeader: false,
          responseBody: false,
        ),
      );
    }

    final s3 = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 60),
      ),
    );
    return ApiClient._(api, bare, s3);
  }
}
