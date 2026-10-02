import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:ytp_app/core/auth_interceptor.dart';
import 'package:ytp_app/core/cookie_capture.dart';
import 'package:ytp_app/core/token_store.dart';

void main() {
  late TokenStore tokens;
  late Dio api;
  late Dio bare;
  late DioAdapter apiAdapter;
  late DioAdapter bareAdapter;
  late int expired;
  late List<String?> refreshCookies;

  setUp(() async {
    expired = 0;
    refreshCookies = [];
    tokens = TokenStore(MemoryKv());
    await tokens.save(accessTokenKey, 'old', maxAgeSeconds: 3600);
    await tokens.save(refreshTokenKey, 'refresh', maxAgeSeconds: 432000);
    bare = Dio(BaseOptions(baseUrl: 'http://x'))
      ..interceptors.addAll([
        InterceptorsWrapper(
          onRequest: (o, h) {
            if (o.path == '/auth/refresh') {
              refreshCookies.add(o.headers['Cookie'] as String?);
            }
            h.next(o);
          },
        ),
        CookieCapture(tokens),
      ]);
    api = Dio(BaseOptions(baseUrl: 'http://x'))
      ..interceptors.add(AuthInterceptor(tokens, bare, () => expired++));
    apiAdapter = DioAdapter(dio: api);
    bareAdapter = DioAdapter(dio: bare);
  });

  test('401 triggers one refresh, then the retry succeeds', () async {
    apiAdapter.onGet(
      '/auth/me',
      (s) => s.reply(401, <String, dynamic>{
        'code': 'token_invalid',
        'detail': 'x',
      }),
    );
    bareAdapter.onPost(
      '/auth/refresh',
      (s) => s.reply(
        200,
        <String, dynamic>{'message': 'ok'},
        headers: {
          'content-type': ['application/json'],
          'set-cookie': ['access_token=new; Max-Age=3600; Path=/'],
        },
      ),
    );
    bareAdapter.onGet(
      '/auth/me',
      (s) => s.reply(200, <String, dynamic>{'id': 'u'}),
    );

    final res = await api.get<Map<String, dynamic>>('/auth/me');
    expect(res.data!['id'], 'u');
    expect(await tokens.accessToken(), 'new');
    expect(refreshCookies, ['refresh_token=refresh']);
    expect(expired, 0);
  });

  test('refresh 401 clears tokens and expires the session once', () async {
    apiAdapter.onGet(
      '/video/mine',
      (s) => s.reply(401, {'code': 'token_invalid'}),
    );
    bareAdapter.onPost(
      '/auth/refresh',
      (s) => s.reply(401, {'code': 'refresh_token_invalid', 'detail': 'x'}),
    );

    await expectLater(
      api.get<dynamic>('/video/mine'),
      throwsA(isA<DioException>()),
    );
    expect(expired, 1);
    expect(await tokens.accessToken(), isNull);
    expect(await tokens.refreshToken(), isNull);
  });

  test('refresh network/5xx keeps the session', () async {
    apiAdapter.onGet(
      '/video/mine',
      (s) => s.reply(401, {'code': 'token_invalid'}),
    );
    bareAdapter.onPost(
      '/auth/refresh',
      (s) => s.reply(503, {'code': 'identity_provider_unavailable'}),
    );
    await expectLater(
      api.get<dynamic>('/video/mine'),
      throwsA(
        isA<DioException>().having(
          (e) => e.response?.statusCode,
          'status',
          503,
        ),
      ),
    );
    expect(expired, 0);
    expect(await tokens.refreshToken(), 'refresh');
  });

  test('skip-listed routes never trigger a refresh', () async {
    apiAdapter.onPost('/auth/login', (s) => s.reply(401, {'code': 'x'}));
    await expectLater(
      api.post<dynamic>('/auth/login'),
      throwsA(isA<DioException>()),
    );
    expect(expired, 0);
    expect(await tokens.accessToken(), 'old');
  });

  test('a non-401 error passes through untouched', () async {
    apiAdapter.onGet(
      '/video/feed',
      (s) => s.reply(503, {'code': 'database_unavailable'}),
    );
    await expectLater(
      api.get<dynamic>('/video/feed'),
      throwsA(isA<DioException>()),
    );
    expect(expired, 0);
  });
}
