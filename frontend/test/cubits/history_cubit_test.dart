import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ytp_app/core/api_exception.dart';
import 'package:ytp_app/cubits/feed/feed_state.dart';
import 'package:ytp_app/cubits/history/history_cubit.dart';
import 'package:ytp_app/cubits/history/history_state.dart';
import 'package:ytp_app/models/watch_progress.dart';
import 'package:ytp_app/services/history_sync.dart';

import '../pages/harness.dart';
import 'helpers.dart';

HistoryEntry entry(String id, DateTime at) => HistoryEntry(
  video: makeVideo(id),
  progress: WatchProgress(
    videoId: id,
    positionSeconds: 60,
    durationSeconds: 600,
    completed: false,
    lastWatchedAt: at,
  ),
);

void main() {
  late MockHistoryService service;
  late HistorySync sync;
  final now = DateTime.now().toUtc();
  final rows = [
    for (var i = 0; i < 5; i++) entry('v$i', now.subtract(Duration(hours: i))),
  ];

  setUp(() {
    service = MockHistoryService();
    sync = HistorySync(browser: FakeBrowser(), service: service)..signedIn('u');
    when(() => service.list(cursor: null, limit: 2)).thenAnswer(
      (_) async => HistoryPage(items: rows.sublist(0, 2), nextCursor: 'c1'),
    );
    when(() => service.list(cursor: 'c1', limit: 2)).thenAnswer(
      (_) async => HistoryPage(items: rows.sublist(2, 4), nextCursor: 'c2'),
    );
    when(() => service.list(cursor: 'c2', limit: 2))
        .thenAnswer((_) async => HistoryPage(items: rows.sublist(4)));
    when(() => service.remove(any())).thenAnswer((_) async {});
    when(() => service.clear()).thenAnswer((_) async {});
  });

  tearDown(() => sync.dispose());

  List<String> ids(HistoryCubit c) => [
    for (final e in c.state.items) e.video.id,
  ];

  test('pages by cursor to the end and fills the bars', () async {
    final cubit = HistoryCubit(sync, limit: 2);
    await cubit.load();
    expect(ids(cubit), ['v0', 'v1']);
    expect(cubit.state.hasMore, isTrue);
    await cubit.loadMore();
    await cubit.loadMore();
    expect(ids(cubit), ['v0', 'v1', 'v2', 'v3', 'v4']);
    expect(cubit.state.hasMore, isFalse);
    await cubit.loadMore(); // nothing more to ask
    verify(() => service.list(cursor: 'c2', limit: 2)).called(1);
    expect(sync.store.peek('v3')!.positionSeconds, 60);
    await cubit.close();
  });

  test('remove hides at once and deletes after the undo window', () {
    fakeAsync((async) {
      final cubit = HistoryCubit(sync, limit: 2)..load();
      async.flushMicrotasks();
      cubit.remove('v0');
      expect(ids(cubit), ['v1']);
      expect(sync.store.peek('v0'), isNull);
      async.elapse(const Duration(seconds: 4));
      verifyNever(() => service.remove(any()));
      async.elapse(const Duration(seconds: 2));
      verify(() => service.remove('v0')).called(1);
      cubit.close();
    });
  });

  test('undo puts it back where it was, and nothing is deleted', () {
    fakeAsync((async) {
      final cubit = HistoryCubit(sync, limit: 2)..load();
      async.flushMicrotasks();
      cubit.remove('v0');
      cubit.undo('v0');
      expect(ids(cubit), ['v0', 'v1']);
      expect(sync.store.peek('v0'), isNotNull);
      async.elapse(const Duration(seconds: 10));
      verifyNever(() => service.remove(any()));
      cubit.close();
    });
  });

  test('a failed delete restores the row with a notice', () {
    fakeAsync((async) {
      when(() => service.remove(any())).thenThrow(
        const ApiException(kind: ApiErrorKind.network, message: 'offline'),
      );
      final cubit = HistoryCubit(sync, limit: 2)..load();
      async.flushMicrotasks();
      cubit.remove('v1');
      async.elapse(const Duration(seconds: 6));
      expect(ids(cubit), ['v0', 'v1']);
      expect(cubit.state.notice!.message, contains('offline'));
      cubit.close();
    });
  });

  test('leaving the page deletes what is waiting to be deleted', () {
    fakeAsync((async) {
      final cubit = HistoryCubit(sync, limit: 2)..load();
      async.flushMicrotasks();
      cubit.remove('v0');
      cubit.close();
      async.flushMicrotasks();
      verify(() => service.remove('v0')).called(1);
    });
  });

  test('clear empties the list, the bars, and the outbox', () async {
    final cubit = HistoryCubit(sync, limit: 2);
    await cubit.load();
    sync.report(
      ProgressReport(videoId: 'v9', positionSeconds: 9, watchedAt: now),
    );
    await cubit.clear();
    expect(cubit.state.items, isEmpty);
    expect(cubit.state.hasMore, isFalse);
    expect(sync.outbox.isEmpty, isTrue);
    expect(sync.store.peek('v0'), isNull);
    await cubit.close();
  });

  test('errors: a failed first load, and a backend without history', () async {
    when(
      () => service.list(cursor: null, limit: 2),
    ).thenThrow(const ApiException(kind: ApiErrorKind.server, message: 'boom'));
    final failed = HistoryCubit(sync, limit: 2);
    await failed.load();
    expect(failed.state.status, ListStatus.failure);
    await failed.close();

    when(() => service.list(cursor: null, limit: 2))
        .thenThrow(ApiException.fromResponse(404, {'code': 'not_found'}));
    final missing = HistoryCubit(sync, limit: 2);
    await missing.load();
    expect(missing.state.unavailable, isTrue);
    expect(sync.available.value, isFalse);
    await missing.close();
  });

  group('day groups', () {
    final today = DateTime(2026, 10, 24); // a Saturday
    String label(DateTime local) => dayLabel(local.toUtc(), today: today);

    test('today, yesterday, weekdays, then dates', () {
      expect(label(DateTime(2026, 10, 24, 23, 59)), 'Today');
      expect(label(DateTime(2026, 10, 24, 0, 1)), 'Today');
      expect(label(DateTime(2026, 10, 23, 23, 59)), 'Yesterday');
      expect(label(DateTime(2026, 10, 22, 12)), 'Thursday');
      expect(label(DateTime(2026, 10, 18, 12)), 'Sunday');
      expect(label(DateTime(2026, 10, 17, 12)), 'Oct 17, 2026');
      expect(label(DateTime(2025, 12, 31, 23)), 'Dec 31, 2025');
    });

    test('consecutive entries on one day share a header', () {
      final days = groupByDay([
        entry('a', DateTime(2026, 10, 24, 10).toUtc()),
        entry('b', DateTime(2026, 10, 24, 9).toUtc()),
        entry('c', DateTime(2026, 10, 23, 9).toUtc()),
      ], now: DateTime(2026, 10, 24, 12));
      expect(
        [for (final d in days) (d.label, d.entries.length)],
        [('Today', 2), ('Yesterday', 1)],
      );
    });
  });
}
