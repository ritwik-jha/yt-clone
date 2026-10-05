import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ytp_app/core/api_exception.dart';
import 'package:ytp_app/cubits/feed/feed_cubit.dart';
import 'package:ytp_app/cubits/feed/feed_state.dart';
import 'package:ytp_app/cubits/my_videos/my_videos_cubit.dart';
import 'package:ytp_app/cubits/video_detail/video_detail_cubit.dart';
import 'package:ytp_app/cubits/video_detail/video_detail_state.dart';
import 'package:ytp_app/models/page_result.dart';
import 'package:ytp_app/models/progress.dart';
import 'package:ytp_app/models/video.dart';

import 'helpers.dart';

ApiException _notFound() => ApiException.fromResponse(404, <String, dynamic>{
  'code': 'video_not_found',
  'detail': 'gone',
});

PageResult<Video> _page(int page, int total, List<String> ids) => PageResult(
  total: total,
  page: page,
  limit: 2,
  items: [for (final id in ids) makeVideo(id)],
);

void main() {
  setUpAll(() => registerFallbackValue(const VideoUpdate()));

  group('FeedCubit', () {
    late MockVideoService videos;
    setUp(() => videos = MockVideoService());

    test('paginates, de-duplicates by id, stops at total', () async {
      when(() => videos.feed(page: 1, limit: 2))
          .thenAnswer((_) async => _page(1, 3, ['a', 'b']));
      // Offset shift: "b" shows up again on page 2.
      when(() => videos.feed(page: 2, limit: 2))
          .thenAnswer((_) async => _page(2, 3, ['b', 'c']));
      final cubit = FeedCubit(videos, limit: 2);

      await cubit.load();
      expect(cubit.state.items.map((v) => v.id), ['a', 'b']);
      expect(cubit.state.hasMore, isTrue);

      await cubit.loadMore();
      expect(cubit.state.items.map((v) => v.id), ['a', 'b', 'c']);
      expect(cubit.state.hasMore, isFalse);

      await cubit.loadMore(); // no-op at the end
      verifyNever(() => videos.feed(page: 3, limit: 2));
    });

    test('first load failure -> failure state; retry recovers', () async {
      when(() => videos.feed(page: 1, limit: 2)).thenThrow(
        const ApiException(kind: ApiErrorKind.network, message: 'offline'),
      );
      final cubit = FeedCubit(videos, limit: 2);
      await cubit.load();
      expect(cubit.state.status, ListStatus.failure);

      when(() => videos.feed(page: 1, limit: 2))
          .thenAnswer((_) async => _page(1, 1, ['a']));
      await cubit.load();
      expect(cubit.state.status, ListStatus.success);
    });

    test('refresh failure keeps existing items', () async {
      when(() => videos.feed(page: 1, limit: 2))
          .thenAnswer((_) async => _page(1, 2, ['a', 'b']));
      final cubit = FeedCubit(videos, limit: 2);
      await cubit.load();
      when(() => videos.feed(page: 1, limit: 2)).thenThrow(
        const ApiException(kind: ApiErrorKind.network, message: 'offline'),
      );
      await cubit.refresh();
      expect(cubit.state.items, hasLength(2));
      expect(cubit.state.status, ListStatus.success);
      expect(cubit.state.error, isNotNull);
    });

    test('remove drops the item and total', () async {
      when(() => videos.feed(page: 1, limit: 2))
          .thenAnswer((_) async => _page(1, 2, ['a', 'b']));
      final cubit = FeedCubit(videos, limit: 2);
      await cubit.load();
      cubit.remove('a');
      expect(cubit.state.items.map((v) => v.id), ['b']);
      expect(cubit.state.total, 1);
    });
  });

  group('VideoDetailCubit', () {
    late MockVideoService videos;
    setUp(() => videos = MockVideoService());

    test(
      'COMPLETED -> ready; recordView fires once and bumps the count',
      () async {
        final v = makeVideo('a', views: 5);
        when(() => videos.detail('a')).thenAnswer((_) async => v);
        when(() => videos.recordView('a')).thenAnswer((_) async {});
        final cubit = VideoDetailCubit(videos, initial: v);
        await cubit.load('a');
        expect(cubit.state, isA<VideoDetailReady>());

        await cubit.recordView();
        await cubit.recordView();
        verify(() => videos.recordView('a')).called(1);
        expect((cubit.state as VideoDetailReady).video.viewsCount, 6);
      },
    );

    test('recordView swallows errors', () async {
      final v = makeVideo('a');
      when(() => videos.detail('a')).thenAnswer((_) async => v);
      when(() => videos.recordView('a')).thenThrow(
        const ApiException(kind: ApiErrorKind.network, message: 'offline'),
      );
      final cubit = VideoDetailCubit(videos);
      await cubit.load('a');
      await cubit.recordView();
      expect(cubit.state, isA<VideoDetailReady>());
    });

    test('404 -> notFound', () async {
      when(() => videos.detail('a')).thenThrow(_notFound());
      final cubit = VideoDetailCubit(videos);
      await cubit.load('a');
      expect(cubit.state, isA<VideoDetailNotFound>());
    });

    test(
      'PROCESSING polls progress then flips to ready when COMPLETED',
      () async {
        final processing = makeVideo('a', status: VideoStatus.processing);
        final done = makeVideo('a', status: VideoStatus.completed);
        var detailCalls = 0;
        when(() => videos.detail('a')).thenAnswer((_) async {
          detailCalls++;
          return detailCalls == 1 ? processing : done;
        });
        when(() => videos.progress('a')).thenAnswer(
          (_) async => const Progress(
            videoId: 'a',
            percent: 100,
            status: VideoStatus.completed,
          ),
        );
        final cubit = VideoDetailCubit(
          videos,
          pollInterval: const Duration(milliseconds: 10),
        );
        await cubit.load('a');
        expect(cubit.state, isA<VideoDetailProcessing>());
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(cubit.state, isA<VideoDetailReady>());
        await cubit.close();
      },
    );

    test(
      'delete -> deleted state; video_not_found counts as deleted',
      () async {
        final v = makeVideo('a');
        when(() => videos.detail('a')).thenAnswer((_) async => v);
        when(() => videos.delete('a')).thenThrow(_notFound());
        final cubit = VideoDetailCubit(videos);
        await cubit.load('a');
        await cubit.delete();
        expect(cubit.state, const VideoDetailDeleted('a'));
      },
    );

    test('update applies the server response', () async {
      final v = makeVideo('a');
      when(() => videos.detail('a')).thenAnswer((_) async => v);
      when(() => videos.update('a', any())).thenAnswer(
        (_) async =>
            v.copyWith(title: 'New', visibility: VideoVisibility.private),
      );
      final cubit = VideoDetailCubit(videos);
      await cubit.load('a');
      await cubit.update(const VideoUpdate(title: 'New'));
      expect((cubit.state as VideoDetailReady).video.title, 'New');
    });
  });

  group('MyVideosCubit', () {
    late MockVideoService videos;
    setUp(() => videos = MockVideoService());

    test(
      'poll updates progress, re-fetches detail on terminal status',
      () async {
        final a = makeVideo('a', status: VideoStatus.processing);
        final b = makeVideo('b', status: VideoStatus.pending);
        when(() => videos.mine(page: 1, limit: 10)).thenAnswer(
          (_) async => PageResult(total: 2, page: 1, limit: 10, items: [a, b]),
        );
        when(() => videos.progress('a')).thenAnswer(
          (_) async => const Progress(
            videoId: 'a',
            percent: 100,
            status: VideoStatus.completed,
          ),
        );
        when(() => videos.progress('b')).thenAnswer(
          (_) async => const Progress(
            videoId: 'b',
            percent: 25,
            status: VideoStatus.processing,
          ),
        );
        when(() => videos.detail('a')).thenAnswer(
          (_) async => makeVideo('a', status: VideoStatus.completed),
        );

        final cubit = MyVideosCubit(videos);
        await cubit.load();
        await cubit.poll();

        expect(cubit.state.items[0].effectiveStatus, VideoStatus.completed);
        expect(cubit.state.items[1].effectiveStatus, VideoStatus.processing);
        expect(cubit.state.progress['b']!.percent, 25);
        await cubit.close();
      },
    );

    test('poll drops an item deleted elsewhere (video_not_found)', () async {
      final a = makeVideo('a', status: VideoStatus.processing);
      when(() => videos.mine(page: 1, limit: 10)).thenAnswer(
        (_) async => PageResult(total: 1, page: 1, limit: 10, items: [a]),
      );
      when(() => videos.progress('a')).thenThrow(_notFound());
      final cubit = MyVideosCubit(videos);
      await cubit.load();
      await cubit.poll();
      expect(cubit.state.items, isEmpty);
      await cubit.close();
    });

    test(
      'paused polling does nothing; delete removes and lowers total',
      () async {
        final a = makeVideo('a', status: VideoStatus.processing);
        when(() => videos.mine(page: 1, limit: 10)).thenAnswer(
          (_) async => PageResult(total: 1, page: 1, limit: 10, items: [a]),
        );
        when(() => videos.delete('a')).thenAnswer((_) async {});
        final cubit = MyVideosCubit(videos);
        await cubit.load();
        cubit.setPaused(true);
        await cubit.poll();
        verifyNever(() => videos.progress(any()));

        await cubit.deleteVideo('a');
        expect(cubit.state.items, isEmpty);
        expect(cubit.state.total, 0);
        await cubit.close();
      },
    );
  });
}
