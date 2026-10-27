// End-to-end flow against the local test backend (SQLite seed + fake
// Cognito + in-memory S3), in headless Chrome. Run the whole pipeline with
// `scripts/run_pipeline.sh`, or by hand:
//
//   cd backend && python scripts/seed_sqlite.py
//   set -a; . tests/support/test.env; set +a
//   uvicorn tests.support.server:app --port 8000 &
//   chromedriver --port=4444 &
//   cd ../frontend && flutter drive -d web-server --headless \
//     --no-web-resources-cdn --browser-dimension=1440x2000 \
//     --web-hostname=127.0.0.1 --web-port=8090 --browser-name=chrome \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/seeded_flow_test.dart \
//     --dart-define=API_BASE_URL=http://127.0.0.1:8000
//
// The expected titles and accounts are the ones in
// backend/tests/support/seed_data.py. Keep the two in step.
import 'dart:async';
import 'dart:js_interop';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:web/web.dart' as web;
import 'package:ytp_app/app/app.dart';
import 'package:ytp_app/platform/browser.dart';
import 'package:ytp_app/widgets/video_grid_card.dart';
import 'package:ytp_app/widgets/video_list_tile.dart';

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
// Alice's seeded watch history (seed_data.HISTORY), newest first.
const _aliceHistory = [
  'Hiking the Western Ghats',
  'City timelapse at night',
  'Fingerstyle guitar basics',
  'Private video diary',
];
const _aliceTitles = [
  'Still transcoding',
  'Hiking the Western Ghats',
  'Ten-minute dal tadka',
  'Unlisted behind the scenes',
  'Private video diary',
];

/// The real browser, except that file choosers return [picks] in order: a
/// test can't click through the OS dialog. Uploads, frame capture, and JPEG
/// conversion are the real thing.
class _ScriptedBrowser implements Browser {
  _ScriptedBrowser(this._real);
  final Browser _real;
  final picks = <PickedFile>[];

  @override
  Future<PickedFile?> pickFile({required String accept}) async =>
      picks.isEmpty ? null : picks.removeAt(0);

  @override
  void Function() listenForDrops(void Function(PickedFile file) onFile) =>
      _real.listenForDrops(onFile);

  @override
  Future<PickedFile?> captureFrame(PickedFile video) =>
      _real.captureFrame(video);

  @override
  Future<PickedFile?> toJpeg(PickedFile image) => _real.toJpeg(image);

  @override
  String objectUrl(PickedFile file) => _real.objectUrl(file);

  @override
  void revokeUrl(String url) => _real.revokeUrl(url);

  @override
  Future<void> put(
    String url,
    PickedFile file, {
    required String contentType,
    UploadProgress? onProgress,
    UploadCancel? cancel,
  }) => _real.put(
    url,
    file,
    contentType: contentType,
    onProgress: onProgress,
    cancel: cancel,
  );

  @override
  void setLeaveWarning(bool on) => _real.setLeaveWarning(on);

  @override
  ValueListenable<bool> get fullscreen => _real.fullscreen;

  @override
  Future<void> setFullscreen(bool on) => _real.setFullscreen(on);

  @override
  String? readLocal(String key) => _real.readLocal(key);

  @override
  void writeLocal(String key, String value) => _real.writeLocal(key, value);

  @override
  void removeLocal(String key) => _real.removeLocal(key);

  @override
  List<String> localKeys(String prefix) => _real.localKeys(prefix);

  @override
  void Function() listenForVisibility({
    required void Function() onHidden,
    required void Function() onVisible,
  }) => _real.listenForVisibility(onHidden: onHidden, onVisible: onVisible);

  @override
  void postOnExit(String url, String json) => _real.postOnExit(url, json);
}

/// 64 KB that claim to be an MP4. The browser can't decode them, so the
/// upload page asks for a thumbnail image instead.
PickedFile _fakeVideo() {
  final blob = web.Blob(
    [Uint8List(64 * 1024).toJS].toJS,
    web.BlobPropertyBag(type: 'video/mp4'),
  );
  return PickedFile(
    name: 'e2e-clip.mp4',
    size: blob.size,
    type: blob.type,
    handle: blob,
  );
}

/// A small PNG drawn on a canvas.
Future<PickedFile> _png() async {
  final canvas = web.HTMLCanvasElement()
    ..width = 320
    ..height = 180;
  final ctx = canvas.getContext('2d')! as web.CanvasRenderingContext2D;
  ctx.fillStyle = '#c62828'.toJS;
  ctx.fillRect(0, 0, 320, 180);
  final done = Completer<web.Blob>();
  canvas.toBlob(((web.Blob? b) => done.complete(b!)).toJS, 'image/png');
  final blob = await done.future;
  return PickedFile(
    name: 'cover.png',
    size: blob.size,
    type: blob.type,
    handle: blob,
  );
}

/// The red bar on a thumbnail (WatchedBar draws it only when watched).
final _watchedBar = find.byWidgetPredicate(
  (w) =>
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith('watched-'),
);

Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) {
      // Let the page settle (data loading in, dialogs opening).
      await tester.pump(const Duration(milliseconds: 400));
      return;
    }
  }
  throw TestFailure('Timed out waiting for $finder');
}

/// Waits until the test server's CDN stand-in (backend
/// tests/support/server.py) served a path ending in [suffix], and checks it
/// was let through rather than refused.
Future<void> _waitForMedia(WidgetTester tester, Dio api, String suffix) async {
  final end = DateTime.now().add(const Duration(seconds: 20));
  List<dynamic> seen = const [];
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 200));
    seen = (await api.get<List<dynamic>>('/_cdn/log')).data!;
    final hits = [
      for (final e in seen)
        if ((e as List<dynamic>).first.toString().endsWith(suffix)) e[1] as int,
    ];
    if (hits.isNotEmpty) {
      expect(hits.first, 200, reason: 'media requests: $seen');
      return;
    }
  }
  throw TestFailure('No media request for *$suffix; saw $seen');
}

Future<void> _type(WidgetTester tester, Finder field, String text) async {
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
  expect(current(), text, reason: 'typing into $field');
}

Future<void> _enter(WidgetTester tester, String label, String text) =>
    _type(tester, find.widgetWithText(TextFormField, label), text);

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

Future<void> _tapButton(WidgetTester tester, String label) =>
    _tap(tester, find.widgetWithText(FilledButton, label));

Future<void> _signIn(WidgetTester tester, String email) async {
  await _pumpUntil(tester, find.widgetWithText(FilledButton, 'Sign In'));
  await _enter(tester, 'Email', email);
  await _enter(tester, 'Password', _password);
  await _tapButton(tester, 'Sign In');
  await _pumpUntil(tester, find.byTooltip('Account'));
}

Future<void> _accountMenu(WidgetTester tester, String item) async {
  await _tap(tester, find.byTooltip('Account'));
  await _pumpUntil(tester, find.text(item));
  // The open menu is built last; the guide may have the same label.
  await _tap(tester, find.text(item).last);
}

Future<void> _signOut(WidgetTester tester) async {
  await _accountMenu(tester, 'Sign out');
  await _pumpUntil(tester, find.widgetWithText(OutlinedButton, 'SIGN IN'));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('browse signed out, sign up, search, watch, upload, edit', (
    tester,
  ) async {
    final api = Dio(BaseOptions(baseUrl: _apiUrl));
    final health = await api.get<Map<String, dynamic>>('/healthz');
    expect(health.data, {'status': 'ok'}, reason: 'backend not up at $_apiUrl');

    final browser = _ScriptedBrowser(createBrowser());
    await tester.pumpWidget(YtpApp(apiBaseUrl: _apiUrl, browser: browser));

    // 1. Signed out, Home shows the public feed, newest first, row by row.
    await _pumpUntil(tester, find.byType(VideoGridCard));
    await _pumpUntil(tester, find.text(_feedTitles.last));
    Offset at(String title) => tester.getTopLeft(find.text(title));
    for (var i = 1; i < _feedTitles.length; i++) {
      final prev = at(_feedTitles[i - 1]);
      final next = at(_feedTitles[i]);
      expect(
        next.dy > prev.dy || (next.dy == prev.dy && next.dx > prev.dx),
        isTrue,
        reason: '${_feedTitles[i]} should follow ${_feedTitles[i - 1]}',
      );
    }
    expect(find.text('Private video diary'), findsNothing);
    expect(find.text('Still transcoding'), findsNothing);

    // 2. Sign up from the masthead's SIGN IN.
    await _tap(tester, find.widgetWithText(OutlinedButton, 'SIGN IN').first);
    await _pumpUntil(tester, find.widgetWithText(FilledButton, 'Sign In'));
    await _tap(tester, find.widgetWithText(TextButton, 'Sign Up'));
    await _pumpUntil(tester, find.text('Create account'));
    final email = 'e2e-${DateTime.now().millisecondsSinceEpoch}@example.com';
    await _enter(tester, 'Name', 'E2E Viewer');
    await _enter(tester, 'Email', email);
    await _enter(tester, 'Password', _password);
    await _tapButton(tester, 'Sign Up');

    // 3. Confirm: a wrong code is rejected, the seeded one works.
    await _pumpUntil(tester, find.text('Confirm Sign Up'));
    await _enter(tester, 'Verification code', '000000');
    await _tapButton(tester, 'Confirm');
    await _pumpUntil(tester, find.text('Invalid verification code'));
    await _enter(tester, 'Verification code', _otp);
    await _tapButton(tester, 'Confirm');

    // 4. Sign in (email carried over): bad password, then the real one,
    // which lands back on Home.
    await _pumpUntil(tester, find.widgetWithText(FilledButton, 'Sign In'));
    expect(find.widgetWithText(TextFormField, email), findsOneWidget);
    await _enter(tester, 'Password', 'Wrong-Passw0rd');
    await _tapButton(tester, 'Sign In');
    await _pumpUntil(tester, find.text('Incorrect email or password'));
    await _enter(tester, 'Password', _password);
    await _tapButton(tester, 'Sign In');
    await _pumpUntil(tester, find.byTooltip('Account'));
    await _pumpUntil(tester, find.byType(VideoGridCard));

    // 5. Search from the masthead.
    await _type(tester, find.widgetWithText(TextField, 'Search'), 'guitar');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await _pumpUntil(tester, find.byType(VideoListTile));
    expect(find.byType(VideoListTile), findsOneWidget);
    expect(find.text('Fingerstyle guitar basics'), findsOneWidget);

    // 6. Watch it: details from the backend, no owner actions. The player
    // asked the CDN stand-in for the playlist with the signed cookies the
    // page got first (POST /video/{id}/playback), and was let through.
    await _tap(tester, find.text('Fingerstyle guitar basics'));
    await _pumpUntil(tester, find.text('SHARE'));
    expect(find.text('Bob Tester'), findsWidgets);
    expect(find.text('EDIT'), findsNothing);
    await _waitForMedia(tester, api, '/master.m3u8');

    // 7. The creator's channel lists their two public, ready videos.
    await _tap(tester, find.text('Bob Tester').first);
    await _pumpUntil(tester, find.textContaining('2 videos'));
    expect(find.text('Uploads'), findsOneWidget);

    // 8. Sign out; sign in as the seeded owner.
    await _signOut(tester);
    await _tap(tester, find.widgetWithText(OutlinedButton, 'SIGN IN').first);
    await _signIn(tester, _alice);

    // 9. Watch history: a bar on the finished video's card on Home; History
    // lists Alice's seeded rows newest first; remove + undo; clear all.
    // (The seeded videos point at a CDN that doesn't exist, so nothing here
    // plays: recording and resume are covered by the widget tests.)
    await _tap(tester, find.text('Home').first);
    await _pumpUntil(tester, find.text('Fingerstyle guitar basics'));
    final guitarCard = find.ancestor(
      of: find.text('Fingerstyle guitar basics'),
      matching: find.byType(VideoGridCard),
    );
    await _pumpUntil(
      tester,
      find.descendant(of: guitarCard, matching: _watchedBar),
    );
    final dalCard = find.ancestor(
      of: find.text('Ten-minute dal tadka'),
      matching: find.byType(VideoGridCard),
    );
    expect(find.descendant(of: dalCard, matching: _watchedBar), findsNothing);

    await _tap(tester, find.text('History'));
    await _pumpUntil(tester, find.text('Watch history'));
    for (final title in _aliceHistory) {
      await _pumpUntil(tester, find.text(title));
    }
    for (var i = 1; i < _aliceHistory.length; i++) {
      expect(
        at(_aliceHistory[i]).dy,
        greaterThan(at(_aliceHistory[i - 1]).dy),
        reason: '${_aliceHistory[i]} should follow ${_aliceHistory[i - 1]}',
      );
    }
    final timelapseRow = find.ancestor(
      of: find.text('City timelapse at night'),
      matching: find.byType(VideoListTile),
    );
    await _tap(
      tester,
      find.descendant(
        of: timelapseRow,
        matching: find.byTooltip('Remove from watch history'),
      ),
    );
    await _pumpUntil(tester, find.text('UNDO'));
    expect(find.text('City timelapse at night'), findsNothing);
    await _tap(tester, find.text('UNDO'));
    await _pumpUntil(tester, find.text('City timelapse at night'));

    await _tap(tester, find.text('Clear all watch history'));
    await _pumpUntil(tester, find.text('CLEAR WATCH HISTORY'));
    await _tap(tester, find.text('CLEAR WATCH HISTORY'));
    await _pumpUntil(tester, find.text('Videos you watch will show up here.'));
    for (final title in _aliceHistory) {
      expect(find.text(title), findsNothing);
    }

    // 10. Your videos lists all of Alice's uploads, private and unfinished too.
    await _accountMenu(tester, 'Your videos');
    await _pumpUntil(tester, find.text('Your videos').last);
    for (final title in _aliceTitles) {
      await _pumpUntil(tester, find.text(title));
    }

    // 11. Edit a title; the backend has it afterwards.
    const newTitle = 'Dal tadka, edited end to end';
    // The Edit button on the same row as the title.
    final titleY = tester.getCenter(find.text('Ten-minute dal tadka')).dy;
    final edits = find.byTooltip('Edit').evaluate().toList();
    edits.sort(
      (a, b) => (tester.getCenter(find.byWidget(a.widget)).dy - titleY)
          .abs()
          .compareTo(
            (tester.getCenter(find.byWidget(b.widget)).dy - titleY).abs(),
          ),
    );
    await _tap(tester, find.byWidget(edits.first.widget));
    await _pumpUntil(tester, find.text('Video details'));
    await _enter(tester, 'Title', newTitle);
    await _tap(tester, find.widgetWithText(FilledButton, 'SAVE'));
    await _pumpUntil(tester, find.text(newTitle));
    final feed = await api.get<Map<String, dynamic>>(
      '/video/feed',
      queryParameters: {'limit': 50},
    );
    final titles = [
      for (final item in feed.data!['items'] as List) item['title'] as String,
    ];
    expect(titles, contains(newTitle));
    expect(titles, isNot(contains('Ten-minute dal tadka')));

    // 12. Upload from the browser: the video can't be decoded, so it asks
    // for a thumbnail image; both go to the presigned URLs, then the save.
    browser.picks
      ..add(_fakeVideo())
      ..add(await _png());
    await _tap(tester, find.widgetWithText(FilledButton, 'UPLOAD VIDEO'));
    await _pumpUntil(tester, find.text('SELECT FILE'));
    await _tapButton(tester, 'SELECT FILE');
    await _pumpUntil(tester, find.textContaining("Couldn't take a thumbnail"));
    expect(find.widgetWithText(TextFormField, 'e2e-clip'), findsOneWidget);
    await _tap(tester, find.text('UPLOAD THUMBNAIL'));
    await _pumpUntil(tester, find.text('CHANGE THUMBNAIL'));
    await _tapButton(tester, 'UPLOAD');
    await _pumpUntil(tester, find.text('Upload complete'));
    await _tapButton(tester, 'GO TO YOUR VIDEOS');
    await _pumpUntil(tester, find.text('e2e-clip'));
    expect(find.text('Pending'), findsOneWidget);

    // 13. Sign out from a signed-in-only page: back to Sign in.
    await _accountMenu(tester, 'Sign out');
    await _pumpUntil(tester, find.widgetWithText(FilledButton, 'Sign In'));
    expect(find.byTooltip('Account'), findsNothing);
  }, skip: !kIsWeb);
}
