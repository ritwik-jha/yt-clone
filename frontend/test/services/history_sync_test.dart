import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ytp_app/core/api_exception.dart';
import 'package:ytp_app/models/watch_progress.dart';
import 'package:ytp_app/platform/video_player.dart';
import 'package:ytp_app/platform/video_stub.dart';
import 'package:ytp_app/services/history_sync.dart';

import '../cubits/helpers.dart';
import '../pages/harness.dart';

WatchProgress progress(String id, int pos, DateTime at) => WatchProgress(
  videoId: id,
  positionSeconds: pos,
  durationSeconds: 600,
  completed: false,
  lastWatchedAt: at,
);

void main() {
  setUpAll(() => registerFallbackValue(<ProgressReport>[]));

  late FakeBrowser browser;
  late MockHistoryService service;
  late HistorySync sync;
  late List<List<ProgressReport>> recorded;

  setUp(() {
    browser = FakeBrowser();
    service = MockHistoryService();
    recorded = [];
    when(() => service.exitUrl).thenReturn('https://app.test/history/progress');
    when(() => service.record(any())).thenAnswer((inv) async {
      final batch = inv.positionalArguments.first as List<ProgressReport>;
      recorded.add(batch);
      return [
        for (final r in batch)
          ProgressResult(videoId: r.videoId, outcome: ProgressOutcome.saved),
      ];
    });
    when(() => service.positions(any())).thenAnswer((_) async => []);
    sync = HistorySync(browser: browser, service: service);
  });

  tearDown(() => sync.dispose());

  ProgressReport report(String id, int pos, DateTime at) =>
      ProgressReport(videoId: id, positionSeconds: pos, watchedAt: at);

  test('records only while signed in', () {
    sync.report(report('a', 10, DateTime.now().toUtc()));
    expect(sync.outbox.isEmpty, isTrue);
    expect(sync.track(StubPlayerController(), 'a'), isNull);

    sync.signedIn('u');
    sync.report(report('a', 10, DateTime.now().toUtc()));
    expect(sync.outbox.pending('a'), isNotNull);
    expect(sync.store.peek('a')!.positionSeconds, 10);
  });

  test('hiding the tab reports the position and posts the outbox', () {
    fakeAsync((async) {
      sync.signedIn('u');
      final player = StubPlayerController()
        ..value = const PlayerValue(duration: Duration(seconds: 600));
      final tracker = sync.track(player, 'a')!;
      player.value = player.value.copyWith(playing: true);
      for (var i = 0; i < 24; i++) {
        async.elapse(const Duration(milliseconds: 250));
        player.value = player.value.copyWith(
          position: player.value.position + const Duration(milliseconds: 250),
        );
      }
      browser.hide();
      final (url, json) = browser.exitPosts.single;
      expect(url, 'https://app.test/history/progress');
      final entries = (jsonDecode(json) as Map)['entries'] as List;
      expect(entries.single['position_seconds'], 6);
      // The keys stay: the closing tab can't read the answer.
      expect(sync.outbox.pending('a'), isNotNull);

      browser.show();
      async.flushMicrotasks();
      expect(recorded, isNotEmpty);
      expect(sync.outbox.isEmpty, isTrue);
      sync.untrack(tracker);
      async.flushTimers();
    });
  });

  test('sign-out flushes, then forgets this user', () async {
    sync.signedIn('u');
    sync.report(report('a', 10, DateTime.now().toUtc()));
    await sync.beforeLogout();
    expect(recorded.single.single.videoId, 'a');
    expect(browser.storage, isEmpty);
    expect(sync.recording, isFalse);
  });

  test('a sign-out whose flush fails still forgets', () async {
    when(() => service.record(any())).thenThrow(
      const ApiException(kind: ApiErrorKind.network, message: 'offline'),
    );
    sync.signedIn('u');
    sync.report(report('a', 10, DateTime.now().toUtc()));
    await sync.beforeLogout();
    expect(browser.storage, isEmpty);
  });

  test('an expired session keeps the reports for next time', () {
    sync.signedIn('u');
    sync.report(report('a', 10, DateTime.now().toUtc()));
    sync.signedOut();
    expect(browser.storage, hasLength(1));
    expect(sync.store.peek('a'), isNull);
  });

  test('resume: the newest of the store, the outbox, and the server', () async {
    final now = DateTime.now().toUtc();
    sync.signedIn('u');
    when(() => service.positions(['a'])).thenAnswer(
      (_) async => [progress('a', 100, now.subtract(const Duration(hours: 1)))],
    );
    expect((await sync.resumePoint('a'))!.positionSeconds, 100);

    // An unsent report from this browser is newer than the server's entry.
    sync.outbox.put(report('a', 250, now));
    when(() => service.positions(['a'])).thenAnswer(
      (_) async => [progress('a', 100, now.subtract(const Duration(hours: 1)))],
    );
    expect((await sync.resumePoint('a'))!.positionSeconds, 250);
  });

  test('resume skips the server when the store just looked it up', () async {
    sync.signedIn('u');
    sync.store.put(progress('a', 42, DateTime.now().toUtc()));
    expect((await sync.resumePoint('a'))!.positionSeconds, 42);
    verifyNever(() => service.positions(any()));
  });

  test('a stale answer updates the bar to the server entry', () async {
    final now = DateTime.now().toUtc();
    when(() => service.record(any())).thenAnswer(
      (_) async => [
        ProgressResult(
          videoId: 'a',
          outcome: ProgressOutcome.stale,
          progress: progress('a', 400, now.add(const Duration(minutes: 1))),
        ),
      ],
    );
    sync.signedIn('u');
    sync.report(report('a', 10, now));
    await sync.outbox.flush();
    expect(sync.store.peek('a')!.positionSeconds, 400);
  });

  test('a backend without history turns recording off', () async {
    when(() => service.positions(any()))
        .thenThrow(ApiException.fromResponse(404, {'code': 'not_found'}));
    sync.signedIn('u');
    expect(await sync.resumePoint('a'), isNull);
    expect(sync.available.value, isFalse);
    expect(sync.recording, isFalse);
    expect(sync.track(StubPlayerController(), 'a'), isNull);
  });

  test('forget and forgetAll drop pending reports and bars', () {
    final now = DateTime.now().toUtc();
    sync.signedIn('u');
    sync
      ..report(report('a', 10, now))
      ..report(report('b', 10, now));
    sync.forget('a');
    expect(sync.outbox.pending('a'), isNull);
    expect(sync.store.peek('a'), isNull);
    sync.forgetAll();
    expect(sync.outbox.isEmpty, isTrue);
    expect(sync.store.peek('b'), isNull);
  });
}
