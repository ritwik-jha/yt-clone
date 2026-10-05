import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ytp_app/core/api_client.dart';
import 'package:ytp_app/core/server_settings.dart';
import 'package:ytp_app/core/token_store.dart';

Future<ServerSettings> _make({
  String compileTime = '',
  bool allow = true,
  Map<String, Object> prefsValues = const {},
  TokenStore? tokens,
}) async {
  SharedPreferences.setMockInitialValues(prefsValues);
  return ServerSettings(
    prefs: await SharedPreferences.getInstance(),
    tokens: tokens ?? TokenStore(MemoryKv()),
    compileTimeUrl: compileTime,
    allowOverride: allow,
  );
}

void main() {
  group('normalize', () {
    test('accepts http(s) URLs, trims, drops trailing slashes', () {
      expect(
        ServerSettings.normalize(' http://10.0.2.2:8000/ '),
        'http://10.0.2.2:8000',
      );
      expect(
        ServerSettings.normalize('https://x.ecs.ap-south-1.on.aws//'),
        'https://x.ecs.ap-south-1.on.aws',
      );
    });

    test('adds http:// when the scheme is missing', () {
      expect(
        ServerSettings.normalize('192.168.1.10:8000'),
        'http://192.168.1.10:8000',
      );
    });

    test('rejects junk', () {
      expect(ServerSettings.normalize(''), isNull);
      expect(ServerSettings.normalize('ftp://host'), isNull);
      expect(ServerSettings.normalize('http://'), isNull);
      expect(ServerSettings.normalize('http://h/?q=1'), isNull);
      expect(ServerSettings.validate('nope nope'), isNotNull);
      expect(ServerSettings.validate('localhost:8000'), isNull);
    });
  });

  test('uses the compile-time URL when nothing was typed in', () async {
    final s = await _make(compileTime: 'http://10.0.2.2:8000/');
    expect(s.url, 'http://10.0.2.2:8000');
  });

  test('is null (asks the user) when there is no URL anywhere', () async {
    expect((await _make()).url, isNull);
  });

  test('a saved override beats the compile-time URL in dev builds', () async {
    final s = await _make(
      compileTime: 'http://10.0.2.2:8000',
      prefsValues: {serverUrlPrefKey: 'http://192.168.1.5:8000'},
    );
    expect(s.url, 'http://192.168.1.5:8000');
  });

  test('release builds ignore a saved override', () async {
    final s = await _make(
      compileTime: 'https://prod.example.com',
      allow: false,
      prefsValues: {serverUrlPrefKey: 'http://evil.example'},
    );
    expect(s.url, 'https://prod.example.com');
    expect(s.canChange, isFalse);
    expect(() => s.update('http://x.test'), throwsStateError);
  });

  test(
    'update persists, repoints the clients, clears tokens, notifies',
    () async {
      final tokens = TokenStore(MemoryKv());
      await tokens.save(accessTokenKey, 'a');
      await tokens.save(refreshTokenKey, 'r', maxAgeSeconds: 100);
      final s = await _make(compileTime: 'http://old:8000', tokens: tokens);
      final client = ApiClient(
        tokens: tokens,
        onSessionExpired: () {},
        baseUrl: '',
      );
      s.attach(client);
      expect(client.api.options.baseUrl, 'http://old:8000');

      var notified = 0;
      s.urlNotifier.addListener(() => notified++);
      await s.update('10.0.2.2:9000');

      expect(s.url, 'http://10.0.2.2:9000');
      expect(client.api.options.baseUrl, 'http://10.0.2.2:9000');
      expect(client.bare.options.baseUrl, 'http://10.0.2.2:9000');
      expect(await tokens.accessToken(), isNull);
      expect(await tokens.refreshToken(), isNull);
      expect(notified, 1);
      expect(
        (await SharedPreferences.getInstance()).getString(serverUrlPrefKey),
        'http://10.0.2.2:9000',
      );

      await s.update('http://10.0.2.2:9000/'); // same URL: no-op
      expect(notified, 1);
    },
  );

  test('reset returns to the compile-time URL', () async {
    final s = await _make(
      compileTime: 'http://default:8000',
      prefsValues: {serverUrlPrefKey: 'http://custom:8000'},
    );
    await s.reset();
    expect(s.url, 'http://default:8000');
  });
}
