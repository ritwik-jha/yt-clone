import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ytp_app/core/api_exception.dart';
import 'package:ytp_app/platform/video_player.dart';
import 'package:ytp_app/services/playback_access.dart';

import '../cubits/helpers.dart';

void main() {
  late MockVideoService videos;
  late List<DateTime> asked;
  // Each authorization lasts an hour from the (fake) clock.
  late DateTime Function() clock;

  setUp(() {
    videos = MockVideoService();
    asked = [];
    when(() => videos.streamUrl(any())).thenAnswer(
      (inv) => 'https://app.test${inv.positionalArguments.first}',
    );
    when(() => videos.authorizePlayback('v1')).thenAnswer((_) async {
      asked.add(clock());
      return clock().add(const Duration(hours: 1));
    });
  });

  const source = PlaybackSource('/media/v1/dash/master.m3u8', StreamKind.hls);

  test('prepare authorizes, then gives the resolved URL', () {
    fakeAsync((async) {
      clock = () => async.getClock(DateTime.utc(2026, 10, 27, 12)).now();
      final access = PlaybackAccess(videos, 'v1', now: clock);
      PlaybackSource? loaded;
      access.prepare(source).then((s) => loaded = s);
      async.flushMicrotasks();
      expect(asked, hasLength(1));
      expect(
        loaded,
        const PlaybackSource(
          'https://app.test/media/v1/dash/master.m3u8',
          StreamKind.hls,
        ),
      );
      expect(access.expiresAt, DateTime.utc(2026, 10, 27, 13));
      access.dispose();
    });
  });

  test('renews five minutes before the cookies expire, again and again', () {
    fakeAsync((async) {
      clock = () => async.getClock(DateTime.utc(2026, 10, 27, 12)).now();
      final access = PlaybackAccess(videos, 'v1', now: clock);
      access.prepare(source);
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 54, seconds: 59));
      expect(asked, hasLength(1));
      async.elapse(const Duration(seconds: 1));
      expect(asked, hasLength(2));
      async.elapse(const Duration(minutes: 55));
      expect(asked, hasLength(3));
      access.dispose();
      async.elapse(const Duration(hours: 3));
      expect(asked, hasLength(3));
    });
  });

  test('a short expiry still waits a little', () {
    fakeAsync((async) {
      clock = () => async.getClock(DateTime.utc(2026, 10, 27, 12)).now();
      when(() => videos.authorizePlayback('v1')).thenAnswer((_) async {
        asked.add(clock());
        return clock().add(const Duration(minutes: 1));
      });
      final access = PlaybackAccess(videos, 'v1', now: clock);
      access.prepare(source);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 29));
      expect(asked, hasLength(1));
      async.elapse(const Duration(seconds: 1));
      expect(asked, hasLength(2));
      access.dispose();
    });
  });

  test('no expiry (unsigned API): nothing to renew', () {
    fakeAsync((async) {
      clock = () => async.getClock(DateTime.utc(2026, 10, 27, 12)).now();
      when(() => videos.authorizePlayback('v1')).thenAnswer((_) async => null);
      final access = PlaybackAccess(videos, 'v1', now: clock);
      access.prepare(source);
      async.flushMicrotasks();
      async.elapse(const Duration(days: 1));
      verify(() => videos.authorizePlayback('v1')).called(1);
      access.dispose();
    });
  });

  test('a failed request still opens the stream', () async {
    clock = DateTime.now;
    when(() => videos.authorizePlayback('v1')).thenAnswer(
      (_) async => throw const ApiException(
        kind: ApiErrorKind.network,
        message: 'offline',
      ),
    );
    final access = PlaybackAccess(videos, 'v1');
    final loaded = await access.prepare(source);
    expect(loaded.url, 'https://app.test/media/v1/dash/master.m3u8');
    expect(await access.renew(), isFalse);
    expect(access.expiresAt, isNull);
    access.dispose();
  });
}
