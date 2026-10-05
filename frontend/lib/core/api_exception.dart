import 'package:dio/dio.dart';

enum ApiErrorKind {
  network,
  timeout,
  badRequest,
  unauthorized,
  notFound,
  conflict,
  throttled,
  server,
  unavailable,
}

/// The only exception type services throw (plan §5.9).
class ApiException implements Exception {
  const ApiException({
    required this.kind,
    required this.message,
    this.statusCode,
    this.code,
    this.fieldErrors = const {},
  });

  final ApiErrorKind kind;
  final String message;
  final int? statusCode;

  /// Stable machine-readable code from the error body (plan §4.3).
  final String? code;

  /// Form field name -> message, from a `validation_error` body.
  final Map<String, String> fieldErrors;

  bool get isNetwork =>
      kind == ApiErrorKind.network || kind == ApiErrorKind.timeout;

  /// 503s and connectivity failures never end the session.
  bool get isTransient => isNetwork || kind == ApiErrorKind.unavailable;

  factory ApiException.fromDio(DioException e) {
    final response = e.response;
    if (response == null) {
      final timeout =
          e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.sendTimeout;
      return ApiException(
        kind: timeout ? ApiErrorKind.timeout : ApiErrorKind.network,
        message: timeout
            ? 'The request timed out. Check your connection and try again.'
            : "Can't reach the server. Check your connection and try again.",
      );
    }
    return ApiException.fromResponse(response.statusCode, response.data);
  }

  factory ApiException.fromResponse(int? status, Object? body) {
    String? code;
    String? message;
    final fields = <String, String>{};

    if (body is Map) {
      final c = body['code'];
      if (c is String) code = c;
      final detail = body['detail'];
      if (detail is String) {
        message = detail;
      } else if (detail is List) {
        final parts = <String>[];
        for (final item in detail) {
          if (item is! Map) continue;
          final loc = item['loc'];
          final raw = item['msg'];
          if (raw is! String) continue;
          final msg = raw.replaceFirst(RegExp(r'^Value error,\s*'), '');
          parts.add(msg);
          if (loc is List && loc.isNotEmpty) {
            fields[loc.last.toString()] = msg;
          }
        }
        if (parts.isNotEmpty) message = parts.join('\n');
      }
    }

    final kind = switch (status) {
      400 => ApiErrorKind.badRequest,
      401 => ApiErrorKind.unauthorized,
      404 => ApiErrorKind.notFound,
      409 => ApiErrorKind.conflict,
      429 => ApiErrorKind.throttled,
      503 => ApiErrorKind.unavailable,
      final s? when s >= 500 => ApiErrorKind.server,
      _ => ApiErrorKind.badRequest,
    };

    return ApiException(
      kind: kind,
      statusCode: status,
      code: code,
      fieldErrors: fields,
      message: message ?? _fallback(kind),
    );
  }

  static String _fallback(ApiErrorKind kind) => switch (kind) {
    ApiErrorKind.unavailable => 'Service temporarily unavailable.',
    ApiErrorKind.server => 'Something went wrong. Please try again.',
    ApiErrorKind.throttled => 'Too many attempts, try again later.',
    ApiErrorKind.notFound => "This isn't available.",
    ApiErrorKind.unauthorized => 'Please sign in again.',
    _ => 'Something went wrong. Please try again.',
  };

  @override
  String toString() => 'ApiException($statusCode, $code, $message)';
}

/// Runs [body], converting any [DioException] into an [ApiException].
Future<T> guardApi<T>(Future<T> Function() body) async {
  try {
    return await body();
  } on DioException catch (e) {
    if (e.error is ApiException) throw e.error! as ApiException;
    throw ApiException.fromDio(e);
  }
}
