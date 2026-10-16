import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ytp_app/core/api_client.dart';
import 'package:ytp_app/core/auth_interceptor.dart';

/// Answers each request with [handler]; records what was sent.
class _Server implements HttpClientAdapter {
  _Server(this.handler);

  final Future<(int, Map<String, dynamic>)> Function(RequestOptions) handler;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final (status, body) = await handler(options);
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  int count(String path) => requests.where((r) => r.path == path).length;

  @override
  void close({bool force = false}) {}
}

void main() {
  late int expired;
  late Dio api;
  late Dio bare;

  /// The session: `fresh` once a refresh succeeded.
  late bool fresh;
  late bool refreshWorks;

  Future<(int, Map<String, dynamic>)> backend(RequestOptions o) async {
    switch (o.path) {
      case '/auth/refresh':
        await Future<void>.delayed(const Duration(milliseconds: 10));
        if (!refreshWorks) {
          return (401, {'code': 'refresh_token_invalid', 'detail': 'x'});
        }
        fresh = true;
        return (200, {'message': 'Session refreshed'});
      case '/video/mine' || '/auth/me':
        return fresh
            ? (200, {'ok': o.path})
            : (401, {'code': 'token_invalid', 'detail': 'x'});
      case '/auth/login':
        return (400, {'code': 'incorrect_credentials', 'detail': 'x'});
      default:
        return (404, {'code': 'not_found', 'detail': 'x'});
    }
  }

  setUp(() {
    expired = 0;
    fresh = false;
    refreshWorks = true;
    final server = _Server(backend);
    bare = Dio(BaseOptions(baseUrl: 'http://api'))..httpClientAdapter = server;
    api = Dio(BaseOptions(baseUrl: 'http://api'))
      ..httpClientAdapter = server
      ..interceptors.add(AuthInterceptor(bare, () => expired++));
  });

  _Server server() => api.httpClientAdapter as _Server;

  test('a 401 refreshes once and the retry succeeds', () async {
    final res = await api.get<Map<String, dynamic>>('/auth/me');
    expect(res.data, {'ok': '/auth/me'});
    expect(server().count('/auth/refresh'), 1);
    expect(server().count('/auth/me'), 2);
    expect(expired, 0);
  });

  test('requests that fail together share one refresh', () async {
    final results = await Future.wait([
      api.get<Map<String, dynamic>>('/auth/me'),
      api.get<Map<String, dynamic>>('/video/mine'),
      api.get<Map<String, dynamic>>('/video/mine'),
    ]);
    expect(results.map((r) => r.data!['ok']), [
      '/auth/me',
      '/video/mine',
      '/video/mine',
    ]);
    expect(server().count('/auth/refresh'), 1);
  });

  test('a rejected refresh expires the session and surfaces the 401', () async {
    refreshWorks = false;
    await expectLater(
      api.get<dynamic>('/video/mine'),
      throwsA(
        isA<DioException>().having(
          (e) => e.response?.statusCode,
          'status',
          401,
        ),
      ),
    );
    expect(expired, 1);
    expect(server().count('/video/mine'), 1);
  });

  test('auth endpoints are never refreshed or retried', () async {
    await expectLater(
      api.post<dynamic>('/auth/login'),
      throwsA(isA<DioException>()),
    );
    expect(server().count('/auth/refresh'), 0);
    expect(AuthInterceptor.skipPaths, contains('/auth/refresh'));
  });

  test('non-401 errors pass straight through', () async {
    await expectLater(api.get<dynamic>('/nope'), throwsA(isA<DioException>()));
    expect(server().count('/auth/refresh'), 0);
  });

  test('ApiClient sends credentials (the auth cookies) on every call', () {
    final client = ApiClient(baseUrl: 'http://api', onSessionExpired: () {});
    expect(client.api.options.extra['withCredentials'], isTrue);
    expect(client.bare.options.extra['withCredentials'], isTrue);
    expect(client.api.options.baseUrl, 'http://api');
  });
}
