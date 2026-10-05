import 'package:dio/dio.dart';

import 'token_store.dart';

final _cookie = RegExp(r'^(access_token|refresh_token)=("?)([^";]*)\2');
final _maxAge = RegExp(r';\s*max-age=(-?\d+)', caseSensitive: false);

/// Reads `Set-Cookie` headers into the [TokenStore] (plan §5.4).
class CookieCapture extends Interceptor {
  CookieCapture(this._tokens);
  final TokenStore _tokens;

  @override
  Future<void> onResponse(
    Response response,
    ResponseInterceptorHandler handler,
  ) async {
    for (final raw in response.headers['set-cookie'] ?? const <String>[]) {
      final match = _cookie.firstMatch(raw);
      if (match == null) continue;
      final name = match.group(1)!;
      final value = match.group(3)!;
      final maxAge = int.tryParse(_maxAge.firstMatch(raw)?.group(1) ?? '');
      if (value.isEmpty || (maxAge != null && maxAge <= 0)) {
        await _tokens.delete(name); // logout clears with ="" and Max-Age=0
      } else {
        await _tokens.save(name, value, maxAgeSeconds: maxAge);
      }
    }
    handler.next(response);
  }
}
