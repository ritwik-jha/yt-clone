import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ytp_app/core/cookie_capture.dart';
import 'package:ytp_app/core/token_store.dart';

Response _res(List<String> cookies) => Response(
  requestOptions: RequestOptions(path: '/auth/login'),
  headers: Headers.fromMap({'set-cookie': cookies}),
);

Future<void> _run(CookieCapture c, Response r) async {
  final handler = ResponseInterceptorHandler();
  await c.onResponse(r, handler);
}

void main() {
  late TokenStore tokens;
  late CookieCapture capture;
  var now = DateTime(2026, 1, 1);

  setUp(() {
    now = DateTime(2026, 1, 1);
    tokens = TokenStore(MemoryKv(), clock: () => now);
    capture = CookieCapture(tokens);
  });

  test('stores a JWT value from both cookies at once', () async {
    await _run(
      capture,
      _res([
        'access_token=aaa.bbb.ccc; HttpOnly; Max-Age=3600; Path=/; Secure',
        'refresh_token=rrr-123; HttpOnly; Max-Age=432000; Path=/auth/refresh',
      ]),
    );
    expect(await tokens.accessToken(), 'aaa.bbb.ccc');
    expect(await tokens.refreshToken(), 'rrr-123');
  });

  test('refresh token expires per Max-Age', () async {
    await _run(capture, _res(['refresh_token=r; Max-Age=60']));
    expect(await tokens.refreshToken(), 'r');
    now = now.add(const Duration(seconds: 61));
    expect(await tokens.refreshToken(), isNull);
  });

  test('quoted values are unwrapped', () async {
    await _run(capture, _res(['access_token="quoted"; Max-Age=10']));
    expect(await tokens.accessToken(), 'quoted');
  });

  test('empty value / Max-Age=0 deletes the token (logout)', () async {
    await tokens.save(accessTokenKey, 'a');
    await tokens.save(refreshTokenKey, 'r');
    await _run(
      capture,
      _res([
        'access_token=""; Max-Age=0; Path=/',
        'refresh_token=; Max-Age=0; Path=/auth/refresh',
      ]),
    );
    expect(await tokens.accessToken(), isNull);
    expect(await tokens.refreshToken(), isNull);
  });

  test('ignores unrelated cookies', () async {
    await _run(capture, _res(['session=zzz; Max-Age=10']));
    expect(await tokens.accessToken(), isNull);
  });
}
