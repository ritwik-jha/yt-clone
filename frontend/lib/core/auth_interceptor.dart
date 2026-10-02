import 'package:dio/dio.dart';

import 'token_store.dart';

/// Adds the Bearer header and performs a single-flight refresh on 401
/// (plan §5.4). Retries go through the `bare` client to avoid deadlocking
/// the queue.
class AuthInterceptor extends QueuedInterceptor {
  AuthInterceptor(this._tokens, this._bare, this._onSessionExpired);

  final TokenStore _tokens;
  final Dio _bare;
  final void Function() _onSessionExpired;

  static const skipPaths = {
    '/auth/signup',
    '/auth/verify-otp',
    '/auth/resend-otp',
    '/auth/forgot-password',
    '/auth/reset-password',
    '/auth/login',
    '/auth/refresh',
    '/auth/logout',
  };

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final token = await _tokens.accessToken();
    if (token != null) options.headers['Authorization'] = 'Bearer $token';
    handler.next(options);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final request = err.requestOptions;
    if (err.response?.statusCode != 401 ||
        skipPaths.contains(request.path) ||
        request.extra['retried'] == true) {
      return handler.next(err);
    }

    final current = await _tokens.accessToken();
    final alreadyRefreshed =
        current != null &&
        request.headers['Authorization'] != 'Bearer $current';

    if (!alreadyRefreshed) {
      bool ok;
      try {
        ok = await _refresh();
      } on DioException catch (e) {
        // Network / 5xx during refresh: keep the session, surface the error.
        return handler.next(e);
      }
      if (!ok) {
        await _tokens.clear();
        _onSessionExpired();
        return handler.next(err);
      }
    }

    request
      ..headers['Authorization'] = 'Bearer ${await _tokens.accessToken()}'
      ..extra['retried'] = true;
    try {
      handler.resolve(await _bare.fetch<dynamic>(request));
    } on DioException catch (e) {
      handler.next(e);
    }
  }

  Future<bool> _refresh() async {
    final refresh = await _tokens.refreshToken();
    if (refresh == null) return false;
    try {
      await _bare.post<dynamic>(
        '/auth/refresh',
        options: Options(headers: {'Cookie': 'refresh_token=$refresh'}),
      );
      return true; // CookieCapture stored the new access token
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) return false;
      rethrow;
    }
  }
}
