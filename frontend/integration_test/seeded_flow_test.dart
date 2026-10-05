// End-to-end flow against the local test backend (SQLite seed + fake
// Cognito), in headless Chrome. Run the whole pipeline with
// `scripts/run_pipeline.sh`, or by hand:
//
//   cd backend && python scripts/seed_sqlite.py
//   set -a; . tests/support/test.env; set +a
//   uvicorn tests.support.server:app --port 8000 &
//   chromedriver --port=4444 &
//   cd ../frontend && flutter drive -d web-server --headless \
//     --no-web-resources-cdn --browser-dimension=420x3000 \
//     --web-hostname=127.0.0.1 --web-port=8090 --browser-name=chrome \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/seeded_flow_test.dart \
//     --dart-define=API_BASE_URL=http://127.0.0.1:8000
//
// The expected titles and accounts are the ones in
// backend/tests/support/seed_data.py. Keep the two in step.
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ytp_app/core/server_settings.dart';
import 'package:ytp_app/core/token_store.dart';
import 'package:ytp_app/main.dart';
import 'package:ytp_app/widgets/video_card.dart';

const _apiUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://127.0.0.1:8000',
);

// seed_data.py
const _password = 'Passw0rd!';
const _otp = '123456';
const _alice = 'alice@example.com';
const _feedTitles = [
  'Hiking the Western Ghats',
  'Fingerstyle guitar basics',
  'Ten-minute dal tadka',
  'City timelapse at night',
];
const _aliceTitles = [
  'Still transcoding',
  'Hiking the Western Ghats',
  'Ten-minute dal tadka',
  'Unlisted behind the scenes',
  'Private video diary',
];

Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) {
      // Let a route transition finish, or the page underneath is still
      // onstage and its fields match too.
      await tester.pump(const Duration(milliseconds: 600));
      return;
    }
  }
  throw TestFailure('Timed out waiting for $finder');
}

Future<void> _enter(WidgetTester tester, String label, String text) async {
  final field = find.widgetWithText(TextFormField, label);
  String current() => tester
      .widget<EditableText>(
        find.descendant(of: field, matching: find.byType(EditableText)),
      )
      .controller
      .text;

  await tester.ensureVisible(field);
  // enterText only taps a field it did not type into last. On the web,
  // tapping a button since then blurred the field and closed its text input
  // connection, so the text would be dropped: tap it first, like a user.
  await tester.tap(field);
  await tester.pump();
  await tester.enterText(field, text);
  await tester.pump();
  expect(current(), text, reason: 'typing into "$label"');
}

Future<void> _tapButton(WidgetTester tester, String label) async {
  final button = find.widgetWithText(FilledButton, label);
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pump();
}

/// Waits for [title] to be built, then scrolls it into view. Run with a
/// tall window (`--browser-dimension=420x3000`) so every seeded card is
/// built without drag-scrolling.
Future<void> _scrollTo(WidgetTester tester, String title) async {
  await _pumpUntil(tester, find.text(title));
  await tester.ensureVisible(find.text(title));
  await tester.pump();
}

Future<void> _logOut(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Account'));
  await _pumpUntil(tester, find.text('Log out'));
  await tester.tap(find.text('Log out'));
  await _pumpUntil(tester, find.widgetWithText(FilledButton, 'Sign In'));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sign up, browse the seeded feed, edit as owner, log out', (
    tester,
  ) async {
    final api = Dio(BaseOptions(baseUrl: _apiUrl));
    final health = await api.get<Map<String, dynamic>>('/healthz');
    expect(health.data, {'status': 'ok'}, reason: 'backend not up at $_apiUrl');

    SharedPreferences.setMockInitialValues({'installed': true});
    final prefs = await SharedPreferences.getInstance();
    final tokens = TokenStore(MemoryKv());
    final settings = ServerSettings(
      prefs: prefs,
      tokens: tokens,
      compileTimeUrl: _apiUrl,
    );
    await tester.pumpWidget(
      YtpApp(prefs: prefs, tokens: tokens, settings: settings),
    );

    // 1. A fresh install with no cookie lands on Sign Up.
    await _pumpUntil(tester, find.text('Create account'));
    final email = 'e2e-${DateTime.now().millisecondsSinceEpoch}@example.com';
    await _enter(tester, 'Name', 'E2E Viewer');
    await _enter(tester, 'Email', email);
    await _enter(tester, 'Password', _password);
    await _tapButton(tester, 'Sign Up');

    // 2. Confirm: a wrong code is rejected, the seeded one works.
    await _pumpUntil(tester, find.text('Confirm Sign Up'));
    await _enter(tester, 'Verification code', '000000');
    await _tapButton(tester, 'Confirm');
    await _pumpUntil(tester, find.text('Invalid verification code'));
    await _enter(tester, 'Verification code', _otp);
    await _tapButton(tester, 'Confirm');

    // 3. Sign in: bad password first, then the real one.
    await _pumpUntil(tester, find.widgetWithText(FilledButton, 'Sign In'));
    await _enter(tester, 'Email', email);
    await _enter(tester, 'Password', 'Wrong-Passw0rd');
    await _tapButton(tester, 'Sign In');
    await _pumpUntil(tester, find.text('Incorrect email or password'));
    await _enter(tester, 'Password', _password);
    await _tapButton(tester, 'Sign In');

    // 4. Home shows the seeded public feed, newest first.
    await _pumpUntil(tester, find.byType(VideoCard));
    for (final (i, title) in _feedTitles.indexed) {
      await _scrollTo(tester, title);
      // Newest first: each title sits below the previous one when both show.
      final prev = i == 0 ? null : find.text(_feedTitles[i - 1]);
      if (prev != null && prev.evaluate().isNotEmpty) {
        expect(
          tester.getTopLeft(find.text(title)).dy,
          greaterThan(tester.getTopLeft(prev).dy),
        );
      }
    }
    expect(find.text('Private video diary'), findsNothing);
    expect(find.text('Still transcoding'), findsNothing);

    // 5. Open a video: details come from the backend.
    await _scrollTo(tester, 'Fingerstyle guitar basics');
    await tester.tap(find.text('Fingerstyle guitar basics'));
    await _pumpUntil(
      tester,
      find.text('Playback is not available in the web build yet'),
    );
    await _pumpUntil(tester, find.textContaining('Bob Tester'));
    expect(find.byTooltip('More options'), findsNothing); // not the owner
    await tester.pageBack();
    await _pumpUntil(tester, find.byType(VideoCard));

    // 6. Log out, sign in as the seeded owner.
    await _logOut(tester);
    await _enter(tester, 'Email', _alice);
    await _enter(tester, 'Password', _password);
    await _tapButton(tester, 'Sign In');
    await _pumpUntil(tester, find.byType(VideoCard));

    // 7. My videos lists all of Alice's uploads, private and unfinished too.
    await tester.tap(find.byTooltip('Account'));
    await _pumpUntil(tester, find.text('My videos'));
    await tester.tap(find.text('My videos'));
    await _pumpUntil(tester, find.byType(VideoCard));
    for (final title in _aliceTitles) {
      await _scrollTo(tester, title);
    }

    // 8. Edit a title as the owner; the backend has it afterwards.
    const newTitle = 'Dal tadka, edited end to end';
    await _scrollTo(tester, 'Ten-minute dal tadka');
    await tester.tap(find.text('Ten-minute dal tadka'));
    await _pumpUntil(tester, find.byTooltip('More options'));
    await tester.tap(find.byTooltip('More options'));
    await _pumpUntil(tester, find.text('Edit'));
    await tester.tap(find.text('Edit'));
    await _pumpUntil(tester, find.widgetWithText(TextFormField, 'Title'));
    await _enter(tester, 'Title', newTitle);
    await tester.tap(find.text('Save'));
    await _pumpUntil(tester, find.text(newTitle));
    await tester.pump(const Duration(seconds: 1));

    final feed = await api.get<Map<String, dynamic>>(
      '/video/feed',
      queryParameters: {'limit': 50},
    );
    final titles = [
      for (final item in feed.data!['items'] as List) item['title'] as String,
    ];
    expect(titles, contains(newTitle));
    expect(titles, isNot(contains('Ten-minute dal tadka')));

    // 9. Back home and log out.
    await tester.pageBack();
    await _pumpUntil(tester, find.text('My videos'));
    await tester.pageBack();
    await _pumpUntil(tester, find.byTooltip('Account'));
    await _logOut(tester);
    // Web only: it expects the web player placeholder and the local test
    // backend, which a phone or emulator can't reach at 127.0.0.1.
  }, skip: !kIsWeb);
}
