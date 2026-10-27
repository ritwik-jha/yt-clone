import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ytp_app/core/api_exception.dart';
import 'package:ytp_app/models/watch_progress.dart';
import 'package:ytp_app/services/history_outbox.dart';

import '../cubits/helpers.dart';
import '../pages/harness.dart';

final _t0 = DateTime.utc(2026, 10, 3, 10);

ProgressReport report(String id, int pos, {int at = 0}) => ProgressReport(
  videoId: id,
  positionSeconds: pos,
  durationSeconds: 600,
  watchedAt: _t0.add(Duration(seconds: at)),
);

List<ProgressResult> saved(List<ProgressReport> sent) => [
  for (final r in sent)
    ProgressResult(videoId: r.videoId, outcome: ProgressOutcome.saved),
];

void main() {
  setUpAll(() => registerFallbackValue(<ProgressReport>[]));

  late FakeBrowser browser;
  late MockHistoryService service;
  late List<List<ProgressReport>> sent;

  HistoryOutbox outbox({DateTime? now}) => HistoryOutbox(
    browser: browser,
    service: service,
    now: () => now ?? _t0.add(const Duration(minutes: 1)),
  );

  setUp(() {
    browser = FakeBrowser();
    service = MockHistoryService();
    sent = [];
    when(() => service.record(any())).thenAnswer((inv) async {
      final batch = inv.positionalArguments.first as List<ProgressReport>;
      sent.add(batch);
      return saved(batch);
    });
  });

  String key(String user, String video) => 'ytp.history.$user.$video';

  test('keeps the newest report per video, also across two tabs', () {
    final tab1 = outbox()..open('u');
    final tab2 = outbox()..open('u');
    tab1.put(report('a', 10, at: 5));
    tab2.put(report('a', 4, at: 1)); // older: dropped
    expect(tab1.pending('a')!.positionSeconds, 10);
    expect(tab2.pending('a')!.positionSeconds, 10);
    tab2.put(report('a', 20, at: 9));
    expect(tab1.pending('a')!.positionSeconds, 20);
    expect(
      ProgressReport.fromJson(
        jsonDecode(browser.storage[key('u', 'a')]!) as Map<String, dynamic>,
      ),
      report('a', 20, at: 9),
    );
    tab1.dispose();
    tab2.dispose();
  });

  test('flush removes answered keys but not one rewritten meanwhile', () {
    fakeAsync((async) {
      final box = outbox()..open('u');
      box
        ..put(report('a', 10))
        ..put(report('b', 20));
      final answer = Completer<List<ProgressResult>>();
      when(() => service.record(any())).thenAnswer((inv) {
        final batch = inv.positionalArguments.first as List<ProgressReport>;
        sent.add(batch);
        return sent.length == 1 ? answer.future : Future.value(saved(batch));
      });
      box.flush();
      async.flushMicrotasks();
      // A newer report for b arrives while the request is out.
      box.put(report('b', 30, at: 5));
      answer.complete(saved(sent.single));
      async.flushMicrotasks();
      // b's key survived the first answer, so the same flush sends it next.
      expect(sent.length, 2);
      expect(sent.last, [report('b', 30, at: 5)]);
      expect(browser.storage, isEmpty);
      box.dispose();
    });
  });

  test('a flush asked for during a flush also sends what came after', () {
    fakeAsync((async) {
      final box = outbox()..open('u');
      final answer = Completer<List<ProgressResult>>();
      when(() => service.record(any())).thenAnswer((inv) {
        final batch = inv.positionalArguments.first as List<ProgressReport>;
        sent.add(batch);
        return sent.length == 1 ? answer.future : Future.value(saved(batch));
      });
      box.put(report('a', 1));
      var done = false;
      box.flush();
      async.flushMicrotasks();
      box.put(report('b', 2, at: 1));
      box.flush().then((_) => done = true);
      answer.complete(saved(sent.single));
      async.flushMicrotasks();
      expect(done, isTrue);
      expect(
        [for (final b in sent) b.map((r) => r.videoId).toList()],
        [
          ['a'],
          ['b'],
        ],
      );
      box.dispose();
    });
  });

  test('flushes 2 s after a report; a network error keeps everything', () {
    fakeAsync((async) {
      final box = outbox()..open('u');
      when(() => service.record(any())).thenThrow(
        const ApiException(kind: ApiErrorKind.network, message: 'offline'),
      );
      box.put(report('a', 10));
      async.elapse(const Duration(milliseconds: 1900));
      verifyNever(() => service.record(any()));
      async.elapse(const Duration(milliseconds: 200));
      verify(() => service.record(any())).called(1);
      expect(box.pending('a'), isNotNull);

      // Retried every 60 s while anything waits.
      when(() => service.record(any())).thenAnswer((inv) async {
        return saved(inv.positionalArguments.first as List<ProgressReport>);
      });
      async.elapse(const Duration(seconds: 60));
      expect(box.pending('a'), isNull);
      expect(box.isEmpty, isTrue);
      async.elapse(const Duration(minutes: 5));
      verify(() => service.record(any())).called(1); // the retry stopped
      box.dispose();
    });
  });

  test('sends 50 at a time, oldest first', () async {
    final box = outbox()..open('u');
    for (var i = 0; i < 120; i++) {
      box.put(report('v$i', i, at: i));
    }
    await box.flush();
    expect(sent.map((b) => b.length), [50, 50, 20]);
    expect(sent.first.first.videoId, 'v0');
    expect(box.isEmpty, isTrue);
    box.dispose();
  });

  test(
    'stale and every other answer clear the key; results are passed on',
    () async {
      final box = outbox()..open('u');
      final seen = <ProgressResult>[];
      box.onResults = seen.addAll;
      when(() => service.record(any())).thenAnswer(
        (_) async => [
          const ProgressResult(videoId: 'a', outcome: ProgressOutcome.stale),
          const ProgressResult(videoId: 'b', outcome: ProgressOutcome.notFound),
        ],
      );
      box
        ..put(report('a', 1))
        ..put(report('b', 1, at: 1));
      await box.flush();
      expect(box.isEmpty, isTrue);
      expect(seen.map((r) => r.outcome), [
        ProgressOutcome.stale,
        ProgressOutcome.notFound,
      ]);
      box.dispose();
    },
  );

  test('reports older than 30 days are dropped unsent', () async {
    final box = outbox(now: _t0.add(const Duration(days: 31)))..open('u');
    box.put(report('old', 1));
    box.put(
      ProgressReport(
        videoId: 'new',
        positionSeconds: 2,
        watchedAt: _t0.add(const Duration(days: 30, hours: 1)),
      ),
    );
    await box.flush();
    expect(sent.single.map((r) => r.videoId), ['new']);
    expect(browser.storage, isEmpty);
    box.dispose();
  });

  test('one user per key; closing with forget removes only theirs', () {
    final box = outbox()..open('alice');
    box.put(report('a', 1));
    box.open('bob');
    expect(box.pending('a'), isNull); // Alice's report isn't Bob's
    box.put(report('b', 1));
    expect(
      browser.storage.keys,
      unorderedEquals([key('alice', 'a'), key('bob', 'b')]),
    );
    box.close(forget: true);
    expect(browser.storage.keys, [key('alice', 'a')]);
    // Alice's report is still there on her next visit.
    box.open('alice');
    expect(box.pending('a')!.positionSeconds, 1);
    box.dispose();
  });

  test('works from memory when storage is blocked', () async {
    final blocked = _BlockedStorage();
    final box = HistoryOutbox(browser: blocked, service: service)..open('u');
    box.put(report('a', 1));
    expect(box.pending('a')!.positionSeconds, 1);
    await box.flush();
    expect(sent.single.single.videoId, 'a');
    expect(box.isEmpty, isTrue);
    box.dispose();
  });

  test('a corrupt stored value is removed', () {
    browser.storage[key('u', 'x')] = 'not json';
    final box = outbox()..open('u');
    expect(box.isEmpty, isTrue);
    expect(browser.storage, isEmpty);
    box.dispose();
  });

  test('drop, dropAll, and the exit body', () {
    final box = outbox()..open('u');
    expect(box.exitBody(), isNull);
    box
      ..put(report('a', 1))
      ..put(report('b', 2, at: 1));
    final body = jsonDecode(box.exitBody()!) as Map<String, dynamic>;
    expect((body['entries'] as List).length, 2);
    box.drop('a');
    expect(box.pending('a'), isNull);
    expect(box.pending('b'), isNotNull);
    box.dropAll();
    expect(box.isEmpty, isTrue);
    expect(browser.storage, isEmpty);
    box.dispose();
  });

  test(
    'a backend without history turns the outbox off and keeps reports',
    () async {
      final box = outbox()..open('u');
      var off = false;
      box.onUnavailable = () => off = true;
      when(() => service.record(any())).thenThrow(
        ApiException.fromResponse(404, {
          'detail': 'Not Found',
          'code': 'not_found',
        }),
      );
      box.put(report('a', 1));
      await box.flush();
      expect(off, isTrue);
      expect(box.pending('a'), isNotNull);
      box.dispose();
    },
  );
}

/// localStorage that is blocked: reads give nothing, writes are lost.
class _BlockedStorage extends FakeBrowser {
  @override
  String? readLocal(String key) => null;

  @override
  void writeLocal(String key, String value) {}

  @override
  List<String> localKeys(String prefix) => const [];
}
