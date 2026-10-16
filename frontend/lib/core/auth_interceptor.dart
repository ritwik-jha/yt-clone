import 'package:dio/dio.dart';

/// Refreshes the session once on a 401 and retries the request (plan §5.4).
///
/// The refresh cookie is HttpOnly and scoped to `/auth`, so the browser sends
/// it to `/auth/refresh` itself. Requests that fail together queue behind one
/// refresh: a request sent before the last successful refresh is retried
/// without refreshing again. Retries go through the `bare` client so they
/// don't deadlock the queue.
class AuthInterceptor extends QueuedInterceptor {
  AuthInterceptor(
    this._bare,
    this._onSessionExpired, {
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final Dio _bare;
  final void Function() _onSessionExpired;
  final DateTime Function() _now;
  DateTime? _refreshedAt;

  static const _sentAt = 'sentAt';
  static const _retried = 'retried';

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
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_sentAt] = _now();
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
        request.extra[_retried] == true) {
      return handler.next(err);
    }

    final sentAt = request.extra[_sentAt] as DateTime?;
    final refreshedSince =
        _refreshedAt != null &&
        sentAt != null &&
        sentAt.isBefore(_refreshedAt!);

    if (!refreshedSince) {
      bool ok;
      try {
        ok = await _refresh();
      } on DioException catch (e) {
        // Network / 5xx during refresh: keep the session, surface the error.
        return handler.next(e);
      }
      if (!ok) {
        _onSessionExpired();
        return handler.next(err);
      }
    }

    request.extra[_retried] = true;
    try {
      handler.resolve(await _bare.fetch<dynamic>(request));
    } on DioException catch (e) {
      handler.next(e);
    }
  }

  Future<bool> _refresh() async {
    try {
      await _bare.post<dynamic>('/auth/refresh');
      _refreshedAt = _now();
      return true;
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) return false;
      rethrow;
    }
  }
}
