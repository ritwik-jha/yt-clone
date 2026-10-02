import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'config.dart';
import 'token_store.dart';

const serverUrlPrefKey = 'api_base_url_override';

/// Resolves and changes the backend URL.
///
/// Order: a URL typed into the app (dev builds only), then the compile-time
/// `API_BASE_URL`. When neither exists in a dev build the app asks for one;
/// in a release build `main()` refuses to start.
class ServerSettings {
  ServerSettings({
    required this._prefs,
    required this._tokens,
    String compileTimeUrl = AppConfig.apiBaseUrl,
    bool allowOverride = AppConfig.allowServerOverride,
  }) : _compileTimeUrl = compileTimeUrl,
       _allowOverride = allowOverride {
    final saved = allowOverride ? _prefs.getString(serverUrlPrefKey) : null;
    urlNotifier = ValueNotifier(
      normalize(saved ?? '') ?? normalize(compileTimeUrl),
    );
  }

  final SharedPreferences _prefs;
  final TokenStore _tokens;
  final String _compileTimeUrl;
  final bool _allowOverride;
  ApiClient? _client;
  late final ValueNotifier<String?> urlNotifier;

  /// The URL requests go to, or null when it still has to be entered.
  String? get url => urlNotifier.value;
  bool get canChange => _allowOverride;
  String? get compileTimeUrl => normalize(_compileTimeUrl);

  /// Called once the [ApiClient] exists so URL changes reach its Dio instances.
  void attach(ApiClient client) {
    _client = client;
    if (url != null) client.setBaseUrl(url!);
  }

  /// Accepts `http(s)://host[:port][/path]`. Returns the cleaned URL without
  /// a trailing slash, or null if it isn't one.
  static String? normalize(String raw) {
    var s = raw.trim();
    if (s.isEmpty || s.contains(RegExp(r'\s'))) return null;
    if (!s.contains('://')) s = 'http://$s';
    final uri = Uri.tryParse(s);
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    return s.replaceAll(RegExp(r'/+$'), '');
  }

  static String? validate(String? raw) => normalize(raw ?? '') == null
      ? 'Enter a URL like http://10.0.2.2:8000'
      : null;

  /// Switches server. The old server's tokens mean nothing to the new one,
  /// so they're cleared.
  Future<void> update(String raw) async {
    if (!_allowOverride) {
      throw StateError('Changing the server URL is disabled in this build.');
    }
    final next = normalize(raw);
    if (next == null) throw ArgumentError.value(raw, 'raw', 'not a valid URL');
    if (next == url) return;
    await _prefs.setString(serverUrlPrefKey, next);
    await _tokens.clear();
    _client?.setBaseUrl(next);
    urlNotifier.value = next;
  }

  /// Goes back to the compile-time URL (or asks again if there is none).
  Future<void> reset() async {
    if (!_allowOverride) return;
    await _prefs.remove(serverUrlPrefKey);
    await _tokens.clear();
    final next = normalize(_compileTimeUrl);
    if (next != null) _client?.setBaseUrl(next);
    urlNotifier.value = next;
  }
}
