import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ytp_app/core/api_exception.dart';
import 'package:ytp_app/models/video.dart';
import 'package:ytp_app/models/watch_progress.dart';
import 'package:ytp_app/widgets/brand_logo.dart';
import 'package:ytp_app/widgets/resume_chip.dart';
import 'package:ytp_app/widgets/video_list_tile.dart';

import 'harness.dart';

void main() {
  setUpAll(Harness.registerFallbacks);

  late Harness h;
  final guitar = video('g', 'Fingerstyle guitar basics', views: 1300);
  final hike = video('h', 'Hiking the Western Ghats', creator: aliceCreator);
  final dal = video('d', 'Ten-minute dal tadka', creator: aliceCreator);
  final now = DateTime.now().toUtc();

  WatchProgress watched(
    String id,
    int pos, {
    Duration ago = const Duration(minutes: 5),
    bool completed = false,
  }) => WatchProgress(
    videoId: id,
    positionSeconds: pos,
    durationSeconds: 61,
    completed: completed,
    lastWatchedAt: now.subtract(ago),
  );

  setUp(() {
    h = Harness()..feed = [hike, guitar, dal];
    h.watched
      ..['g'] = watched('g', 61, completed: true)
      ..['h'] = watched('h', 30, ago: const Duration(days: 1));
    when(() => h.videos.recordView(any())).thenAnswer((_) async {});
    when(() => h.videos.detail('g')).thenAnswer(
      (_) async => guitar.copyWith(
        status: VideoStatus.completed,
        visibility: VideoVisibility.public,
      ),
    );
    when(() => h.videos.detail('h')).thenAnswer(
      (_) async => hike.copyWith(
        status: VideoStatus.completed,
        visibility: VideoVisibility.public,
      ),
    );
    when(() => h.videos.detail('d'))
        .thenAnswer((_) async => dal.copyWith(status: VideoStatus.completed));
    when(() => h.auth.logout()).thenAnswer((_) async {});
  });

  Finder bar(String id) => find.byKey(ValueKey('watched-$id'));

  group('guide and gating', () {
    testWidgets('signed out, the guide has no History', (tester) async {
      await h.pump(tester);
      expect(find.text('History'), findsNothing);
    });

    testWidgets('signed in, History in the guide opens the page', (
      tester,
    ) async {
      await h.pump(tester, user: alice);
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();
      expect(location(tester), '/feed/history');
      expect(find.text('Watch history'), findsOneWidget);
    });

    testWidgets('signed out, /feed/history goes to Sign in and back', (
      tester,
    ) async {
      await h.pump(tester, location: '/feed/history');
      expect(location(tester), '/signin?next=%2Ffeed%2Fhistory');
    });
  });

  group('History page', () {
    testWidgets('rows by day, newest first, with bars and "Watched ..."', (
      tester,
    ) async {
      await h.pump(tester, user: alice, location: '/feed/history');
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Yesterday'), findsOneWidget);
      double y(String t) => tester.getTopLeft(find.text(t)).dy;
      expect(y('Today'), lessThan(y(guitar.title)));
      expect(y(guitar.title), lessThan(y('Yesterday')));
      expect(y('Yesterday'), lessThan(y(hike.title)));
      expect(find.text('Watched 5 minutes ago'), findsOneWidget);
      expect(find.text('Watched 1 day ago'), findsOneWidget);
      expect(find.byType(VideoListTile), findsNWidgets(2));
      // Full bar for the finished video, half for the other.
      expect(
        tester.getSize(bar('g')).width,
        tester.getSize(bar('g').first).width,
      );
      final full = tester.getSize(bar('g')).width;
      final half = tester.getSize(bar('h')).width;
      expect(half / full, closeTo(30 / 61, 0.01));
    });

    testWidgets('remove hides the row; UNDO brings it back', (tester) async {
      await h.pump(tester, user: alice, location: '/feed/history');
      final remove = find.byTooltip('Remove from watch history');
      await tester.tap(remove.first);
      await tester.pumpAndSettle(); // the snack bar slides in
      expect(find.text(guitar.title), findsNothing);
      expect(find.text('Removed from watch history'), findsOneWidget);
      await tester.tap(find.text('UNDO'));
      await tester.pumpAndSettle();
      expect(find.text(guitar.title), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      verifyNever(() => h.history.remove(any()));
    });

    testWidgets('remove without undo deletes it on the server', (tester) async {
      await h.pump(tester, user: alice, location: '/feed/history');
      await tester.tap(find.byTooltip('Remove from watch history').first);
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      verify(() => h.history.remove('g')).called(1);
      expect(find.text(guitar.title), findsNothing);
    });

    testWidgets('clear all asks first, then empties the page', (tester) async {
      await h.pump(tester, user: alice, location: '/feed/history');
      await tester.tap(find.text('Clear all watch history'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('CANCEL'));
      await tester.pumpAndSettle();
      verifyNever(() => h.history.clear());

      await tester.tap(find.text('Clear all watch history'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('CLEAR WATCH HISTORY'));
      await tester.pumpAndSettle();
      verify(() => h.history.clear()).called(1);
      expect(find.text('Videos you watch will show up here.'), findsOneWidget);
    });

    testWidgets('an error offers Retry', (tester) async {
      h.watched.clear();
      await h.pump(tester, user: alice, location: '/feed/history');
      expect(find.text('Videos you watch will show up here.'), findsOneWidget);
      when(
        () => h.history.list(
          cursor: any(named: 'cursor'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer(
        (_) async => throw const ApiException(
          kind: ApiErrorKind.server,
          message: 'boom',
        ),
      );
      await tester.tap(find.text('Home'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('a backend without history says so', (tester) async {
      await h.pump(tester, user: alice);
      when(
        () => h.history.list(
          cursor: any(named: 'cursor'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer(
        (_) async =>
            throw ApiException.fromResponse(404, {'code': 'not_found'}),
      );
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();
      expect(
        find.text("Watch history isn't available on this server."),
        findsOneWidget,
      );
    });
  });

  group('bars on thumbnails', () {
    testWidgets('signed in, watched cards on Home carry a bar', (tester) async {
      await h.pump(tester, user: alice);
      expect(bar('g'), findsOneWidget);
      expect(bar('h'), findsOneWidget);
      expect(bar('d'), findsNothing);
      // One lookup for the whole grid.
      verify(() => h.history.positions(any())).called(1);
    });

    testWidgets('signed out, no bars and no lookups', (tester) async {
      await h.pump(tester);
      expect(bar('g'), findsNothing);
      verifyNever(() => h.history.positions(any()));
    });
  });

  group('watch page', () {
    testWidgets('resumes where the user stopped; START OVER rewinds', (
      tester,
    ) async {
      await h.pump(tester, user: alice, location: '/watch?v=h');
      final player = h.players.single;
      expect(player.startAt, const Duration(seconds: 28));
      expect(find.text('Resumed from 0:28'), findsOneWidget);
      await tester.tap(find.text('START OVER'));
      await tester.pump();
      expect(player.value.position, Duration.zero);
      expect(find.byType(ResumeChip), findsOneWidget);
      expect(find.text('START OVER'), findsNothing);
    });

    testWidgets('the chip goes away by itself', (tester) async {
      await h.pump(tester, user: alice, location: '/watch?v=h');
      expect(find.text('Resumed from 0:28'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('Resumed from 0:28'), findsNothing);
    });

    testWidgets('a finished video starts from the beginning', (tester) async {
      await h.pump(tester, user: alice, location: '/watch?v=g');
      expect(h.players.single.startAt, isNull);
      expect(find.byType(ResumeChip), findsNothing);
    });

    testWidgets('signed out, nothing is looked up', (tester) async {
      await h.pump(tester, location: '/watch?v=h');
      expect(h.players.single.startAt, isNull);
      verifyNever(() => h.history.positions(any()));
    });

    testWidgets('playing then hiding the tab sends the position', (
      tester,
    ) async {
      await h.pump(tester, user: alice, location: '/watch?v=d');
      final player = h.players.single;
      player.value = player.value.copyWith(
        duration: const Duration(seconds: 61),
      );
      // Six seconds of playback, as `timeupdate` reports it.
      for (var i = 1; i <= 24; i++) {
        player.value = player.value.copyWith(
          position: Duration(milliseconds: 250 * i),
        );
      }
      h.browser.hide();
      final (url, json) = h.browser.exitPosts.single;
      expect(url, 'http://api.test/history/progress');
      final entry =
          ((jsonDecode(json) as Map)['entries'] as List).single as Map;
      expect(entry['video_id'], 'd');
      expect(entry['position_seconds'], 6);
      expect(entry['duration_seconds'], 61);
      // The report also waits in localStorage until the server has it.
      expect(h.browser.storage.keys.single, 'ytp.history.alice.d');

      // Back on the page: sent, and the key is gone.
      h.browser.show();
      await tester.pumpAndSettle();
      verify(() => h.history.record(any())).called(1);
      expect(h.browser.storage, isEmpty);
      // And Home's card for it now has a bar.
      await tester.tap(find.byType(BrandLogo));
      await settle(tester);
      expect(bar('d'), findsOneWidget);
    });

    testWidgets('signing out sends what is waiting, then forgets it', (
      tester,
    ) async {
      await h.pump(tester, user: alice);
      h.browser.storage['ytp.history.alice.x'] = jsonEncode(
        ProgressReport(
          videoId: 'x',
          positionSeconds: 9,
          watchedAt: now,
        ).toJson(),
      );
      h.browser.storage['ytp.history.bob.y'] = '{}';
      await tester.tap(find.byTooltip('Account'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      final sent =
          verify(() => h.history.record(captureAny())).captured.single
              as List<ProgressReport>;
      expect(sent.single.videoId, 'x');
      expect(h.browser.storage.keys, ['ytp.history.bob.y']);
    });
  });
}
