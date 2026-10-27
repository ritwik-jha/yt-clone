import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ytp_app/core/api_exception.dart';
import 'package:ytp_app/models/watch_progress.dart';
import 'package:ytp_app/services/watch_progress_store.dart';

import '../cubits/helpers.dart';

WatchProgress progress(String id, int pos, {int day = 3}) => WatchProgress(
  videoId: id,
  positionSeconds: pos,
  durationSeconds: 600,
  completed: false,
  lastWatchedAt: DateTime.utc(2026, 10, day),
);

void main() {
  late MockHistoryService service;
  late List<List<String>> asked;

  setUp(() {
    service = MockHistoryService();
    asked = [];
    when(() => service.positions(any())).thenAnswer((inv) async {
      final ids = inv.positionalArguments.first as List<String>;
      asked.add(ids);
      return [
        for (final id in ids)
          if (id != 'unwatched') progress(id, 60),
      ];
    });
  });

  test('ids asked for together go out as one request', () {
    fakeAsync((async) {
      final store = WatchProgressStore(service)..enable();
      final a = store.watch('a');
      store
        ..watch('b')
        ..watch('unwatched')
        ..watch('a');
      expect(asked, isEmpty);
      async.flushTimers();
      expect(asked, [
        ['a', 'b', 'unwatched'],
      ]);
      expect(a.value!.positionSeconds, 60);
      expect(store.peek('unwatched'), isNull);
      // Known now, also when never watched: not asked again.
      store
        ..watch('a')
        ..watch('unwatched');
      async.flushTimers();
      expect(asked.length, 1);
    });
  });

  test('more than 50 ids are split', () {
    fakeAsync((async) {
      final store = WatchProgressStore(service)..enable();
      for (var i = 0; i < 120; i++) {
        store.watch('v$i');
      }
      async.flushTimers();
      expect(asked.map((ids) => ids.length), [50, 50, 20]);
    });
  });

  test('signed out: nothing is asked and bars are empty', () {
    fakeAsync((async) {
      final store = WatchProgressStore(service);
      store.watch('a');
      async.flushTimers();
      expect(asked, isEmpty);
      store
        ..enable()
        ..put(progress('a', 9));
      expect(store.peek('a'), isNotNull);
      store.disable();
      expect(store.peek('a'), isNull);
    });
  });

  test('keeps the newest entry; remove and clear empty the bars', () {
    final store = WatchProgressStore(service)..enable();
    store.put(progress('a', 100, day: 4));
    store.put(progress('a', 50, day: 3)); // older: ignored
    expect(store.peek('a')!.positionSeconds, 100);
    store.put(progress('b', 1));
    store.remove('a');
    expect(store.peek('a'), isNull);
    expect(store.isFresh('a', const Duration(minutes: 1)), isTrue);
    store.clear();
    expect(store.peek('b'), isNull);
  });

  test('a failed lookup is asked again later; no history turns it off', () {
    fakeAsync((async) {
      final store = WatchProgressStore(service)..enable();
      when(() => service.positions(any())).thenThrow(
        const ApiException(kind: ApiErrorKind.network, message: 'offline'),
      );
      store.watch('a');
      async.flushTimers();
      expect(store.isFresh('a', const Duration(days: 1)), isFalse);

      var off = false;
      store.onUnavailable = () => off = true;
      when(() => service.positions(any()))
          .thenThrow(ApiException.fromResponse(404, {'code': 'not_found'}));
      store.watch('a');
      async.flushTimers();
      expect(off, isTrue);
    });
  });
}
