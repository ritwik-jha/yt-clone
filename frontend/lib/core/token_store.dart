import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Minimal key/value surface so tests can swap secure storage for a map.
abstract class SecureKv {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class FlutterSecureKv implements SecureKv {
  const FlutterSecureKv([this._storage = const FlutterSecureStorage()]);
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class MemoryKv implements SecureKv {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

const accessTokenKey = 'access_token';
const refreshTokenKey = 'refresh_token';

/// Wraps secure storage with an in-memory cache (plan §5.5).
class TokenStore {
  TokenStore(this._kv, {DateTime Function()? clock})
    : _now = clock ?? DateTime.now;

  final SecureKv _kv;
  final DateTime Function() _now;
  final Map<String, String?> _cache = {};

  String _expKey(String name) => '${name}_expires_at';

  Future<String?> _get(String key) async {
    if (_cache.containsKey(key)) return _cache[key];
    final value = await _kv.read(key);
    _cache[key] = value;
    return value;
  }

  /// Returns whatever is stored; the server's 401 drives the refresh.
  Future<String?> accessToken() => _get(accessTokenKey);

  /// Null once the refresh token has expired (plan D8).
  Future<String?> refreshToken() async {
    final token = await _get(refreshTokenKey);
    if (token == null) return null;
    final exp = int.tryParse(await _get(_expKey(refreshTokenKey)) ?? '');
    if (exp != null && _now().millisecondsSinceEpoch >= exp) return null;
    return token;
  }

  Future<void> save(String name, String value, {int? maxAgeSeconds}) async {
    await _put(name, value);
    if (maxAgeSeconds != null) {
      final exp = _now()
          .add(Duration(seconds: maxAgeSeconds))
          .millisecondsSinceEpoch;
      await _put(_expKey(name), exp.toString());
    } else {
      await _remove(_expKey(name));
    }
  }

  Future<void> delete(String name) async {
    await _remove(name);
    await _remove(_expKey(name));
  }

  Future<void> clear() async {
    for (final n in const [accessTokenKey, refreshTokenKey]) {
      await delete(n);
    }
  }

  Future<void> _put(String key, String value) async {
    _cache[key] = value;
    await _kv.write(key, value);
  }

  Future<void> _remove(String key) async {
    _cache[key] = null;
    await _kv.delete(key);
  }
}
