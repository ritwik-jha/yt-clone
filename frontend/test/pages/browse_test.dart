import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ytp_app/core/api_exception.dart';
import 'package:ytp_app/models/progress.dart';
import 'package:ytp_app/models/video.dart';
import 'package:ytp_app/platform/video_player.dart';
import 'package:ytp_app/services/video_service.dart';
import 'package:ytp_app/widgets/video_grid_card.dart';
import 'package:ytp_app/widgets/video_list_tile.dart';

import 'harness.dart';

void main() {
  setUpAll(Harness.registerFallbacks);

  late Harness h;
  final guitar = video('g', 'Fingerstyle guitar basics', views: 1300);
  final hike = video(
    'h',
    'Hiking the Western Ghats',
    creator: aliceCreator,
    views: 42,
    description: 'Two days on the trail.',
  );
  final dal = video(
    'd',
    'Ten-minute dal tadka',
    creator: aliceCreator,
    views: 7,
  );

  setUp(() {
    h = Harness()..feed = [hike, guitar, dal];
    when(() => h.videos.recordView(any())).thenAnswer((_) async {});
  });

  group('home', () {
    testWidgets('signed out: the feed in a grid, creator chips, SIGN IN', (
      tester,
    ) async {
      await h.pump(tester);
      expect(find.byType(VideoGridCard), findsNWidgets(3));
      for (final title in [hike.title, guitar.title, dal.title]) {
        expect(find.text(title), findsOneWidget);
      }
      expect(find.text('SIGN IN'), findsWidgets);
      // Chips: All, Most viewed, then each creator once.
      expect(find.text('Most viewed'), findsOneWidget);
      expect(find.widgetWithText(InkWell, 'Alice Tester'), findsOneWidget);
      expect(find.widgetWithText(InkWell, 'Bob Tester'), findsOneWidget);
      expect(find.text('Your videos'), findsNothing);
    });

    testWidgets('Most viewed re-sorts; a creator chip narrows to them', (
      tester,
    ) async {
      await h.pump(tester);
      await tester.tap(find.text('Most viewed'));
      await tester.pumpAndSettle();
      verify(
        () => h.videos.feed(
          page: 1,
          limit: any(named: 'limit'),
          sort: VideoSort.popular,
        ),
      ).called(1);
      double y(String t) => tester.getTopLeft(find.text(t)).dy;
      double x(String t) => tester.getTopLeft(find.text(t)).dx;
      // Most viewed first: guitar (1.3K) in the first slot.
      expect(x(guitar.title), lessThan(x(hike.title)));
      expect(y(guitar.title), y(hike.title));

      await tester.tap(find.widgetWithText(InkWell, 'Bob Tester'));
      await tester.pumpAndSettle();
      expect(find.byType(VideoGridCard), findsOneWidget);
      expect(find.text(guitar.title), findsOneWidget);
    });

    testWidgets('signed in: account menu and upload in the masthead', (
      tester,
    ) async {
      await h.pump(tester, user: alice);
      expect(find.text('SIGN IN'), findsNothing);
      expect(find.byTooltip('Upload video'), findsOneWidget);
      expect(find.text('Your videos'), findsOneWidget); // sidebar
      await tester.tap(find.byTooltip('Account'));
      await tester.pumpAndSettle();
      expect(find.text('a@x.co'), findsOneWidget);
      expect(find.text('Sign out'), findsOneWidget);
    });

    testWidgets('feed failure shows the error with Retry', (tester) async {
      await h.pump(tester);
      when(
        () => h.videos.feed(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
          sort: any(named: 'sort'),
        ),
      ).thenThrow(
        const ApiException(kind: ApiErrorKind.network, message: 'offline'),
      );
      await tester.tap(find.text('Most viewed'));
      await tester.pumpAndSettle();
      expect(find.text('offline'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('narrow window: no guide, the menu opens a drawer', (
      tester,
    ) async {
      await h.pump(tester, size: const Size(420, 900));
      expect(find.text('Home'), findsNothing);
      await tester.tap(find.byTooltip('Menu'));
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
    });
  });

  group('watch', () {
    setUp(() {
      when(() => h.videos.detail('g')).thenAnswer(
        (_) async => guitar.copyWith(
          status: VideoStatus.completed,
          visibility: VideoVisibility.public,
        ),
      );
    });

    testWidgets('a card opens the watch page, which plays the HLS stream', (
      tester,
    ) async {
      await h.pump(tester);
      await tester.tap(find.text(guitar.title));
      await tester.pumpAndSettle();
      expect(location(tester), '/watch?v=g');

      expect(h.players, hasLength(1));
      final player = h.players.single;
      expect(
        player.source,
        const PlaybackSource('https://cdn/g/master.m3u8', StreamKind.hls),
      );
      expect(find.text('Bob Tester'), findsWidgets);
      // Playback started, so this view is already counted.
      expect(find.text('1,301 views • Jan 1, 2026'), findsOneWidget);
      // Up next: the rest of the feed, not this video.
      expect(find.byType(VideoListTile), findsNWidgets(2));
      // Not the owner.
      expect(find.text('EDIT'), findsNothing);
      // The stub autoplayed: one view counted.
      verify(() => h.videos.recordView('g')).called(1);
    });

    testWidgets('player controls drive the controller', (tester) async {
      await h.pump(tester, location: '/watch?v=g');
      final player = h.players.single;
      expect(player.value.playing, isTrue);
      await tester.tap(find.byTooltip('Pause (k)'));
      await tester.pump();
      expect(player.value.playing, isFalse);
      await tester.tap(find.byTooltip('Mute (m)'));
      await tester.pump();
      expect(player.value.muted, isTrue);
      await tester.tap(find.byTooltip('Full screen (f)'));
      await tester.pumpAndSettle();
      expect(h.browser.fullscreen.value, isTrue);
      // Fullscreen: the player only, no masthead.
      expect(find.byTooltip('Menu'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pumpAndSettle();
      expect(h.browser.fullscreen.value, isFalse);
    });

    testWidgets('From <creator> lists only their videos', (tester) async {
      await h.pump(tester, location: '/watch?v=g');
      await tester.tap(find.text('From Bob Tester'));
      await tester.pumpAndSettle();
      // Bob's only video is this one.
      expect(find.byType(VideoListTile), findsNothing);
      expect(find.text('Nothing else to watch yet.'), findsOneWidget);
    });

    testWidgets('the owner can edit and delete', (tester) async {
      final mine = hike.copyWith(
        status: VideoStatus.completed,
        visibility: VideoVisibility.unlisted,
      );
      when(() => h.videos.detail('h')).thenAnswer((_) async => mine);
      when(() => h.videos.update('h', any())).thenAnswer(
        (inv) async => mine.copyWith(
          title: (inv.positionalArguments[1] as VideoUpdate).title,
        ),
      );
      when(() => h.videos.delete('h')).thenAnswer((_) async {});
      when(
        () => h.videos.mine(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer((_) async => page([]));
      await h.pump(tester, location: '/watch?v=h', user: alice);
      expect(find.text('Unlisted'), findsOneWidget);

      await tester.tap(find.text('EDIT'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Title'),
        'Western Ghats, day one',
      );
      await tester.pump();
      await tester.tap(find.text('SAVE'));
      await tester.pumpAndSettle();
      verify(
        () => h.videos.update(
          'h',
          any(
            that: isA<VideoUpdate>().having((u) => u.toJson(), 'json', {
              'title': 'Western Ghats, day one',
            }),
          ),
        ),
      ).called(1);
      expect(find.text('Western Ghats, day one'), findsWidgets);

      await tester.tap(find.text('DELETE'));
      await tester.pumpAndSettle();
      expect(find.text('Permanently delete this video?'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(TextButton, 'DELETE'),
        ),
      );
      await tester.pumpAndSettle();
      verify(() => h.videos.delete('h')).called(1);
      expect(location(tester), '/my-videos');
    });

    testWidgets('the owner sees processing progress instead of a player', (
      tester,
    ) async {
      when(() => h.videos.detail('h')).thenAnswer(
        (_) async => video(
          'h',
          hike.title,
          creator: aliceCreator,
          status: VideoStatus.processing,
          visibility: VideoVisibility.public,
        ),
      );
      when(() => h.videos.progress('h')).thenAnswer(
        (_) async => const Progress(
          videoId: 'h',
          percent: 40,
          status: VideoStatus.processing,
        ),
      );
      await h.pump(tester, location: '/watch?v=h', user: alice);
      expect(
        find.text('Processing. It will play here when ready.'),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 6));
      expect(find.text('40%'), findsOneWidget);
      expect(h.players.single.source, isNull);
    });

    testWidgets('a missing video says so', (tester) async {
      when(() => h.videos.detail('zz')).thenThrow(
        ApiException.fromResponse(404, <String, dynamic>{
          'code': 'video_not_found',
          'detail': 'Video not found',
        }),
      );
      await h.pump(tester, location: '/watch?v=zz');
      expect(find.text('Video unavailable'), findsOneWidget);
    });
  });

  group('search', () {
    testWidgets('Enter in the search box opens results for the query', (
      tester,
    ) async {
      when(
        () => h.videos.search(
          'guitar',
          page: any(named: 'page'),
          limit: any(named: 'limit'),
          sort: any(named: 'sort'),
        ),
      ).thenAnswer((_) async => page([guitar]));
      await h.pump(tester);
      await tester.enterText(
        find.widgetWithText(TextField, 'Search'),
        'guitar',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(location(tester), '/results?search_query=guitar');
      expect(find.byType(VideoListTile), findsOneWidget);
      // The query stays in the box.
      expect(find.widgetWithText(TextField, 'guitar'), findsOneWidget);
    });

    testWidgets('no results says so', (tester) async {
      when(
        () => h.videos.search(
          any(),
          page: any(named: 'page'),
          limit: any(named: 'limit'),
          sort: any(named: 'sort'),
        ),
      ).thenAnswer((_) async => page([]));
      await h.pump(tester, location: '/results?search_query=zither');
      expect(find.textContaining('No results for "zither"'), findsOneWidget);
    });
  });

  group('channel', () {
    testWidgets('HOME features the latest upload, then the shelves', (
      tester,
    ) async {
      await h.pump(tester, location: '/channel/alice');
      expect(find.text('Alice Tester'), findsWidgets);
      expect(find.text('2 videos • Joined June 2025'), findsOneWidget);
      expect(find.text('Two days on the trail.'), findsOneWidget);
      expect(find.text('Uploads'), findsOneWidget);
      expect(find.text('PLAY ALL'), findsWidgets);
      expect(find.text('MANAGE VIDEOS'), findsNothing);
    });

    testWidgets('VIDEOS tab is a grid; the owner can manage', (tester) async {
      await h.pump(tester, location: '/channel/alice', user: alice);
      expect(find.text('MANAGE VIDEOS'), findsOneWidget);
      await tester.tap(find.text('VIDEOS'));
      await tester.pumpAndSettle();
      expect(location(tester), '/channel/alice/videos');
      expect(find.byType(VideoGridCard), findsNWidgets(2));
      expect(find.text('Recently uploaded'), findsOneWidget);
    });

    testWidgets('an unknown channel says so', (tester) async {
      h.missingChannels.add('nobody');
      await h.pump(tester, location: '/channel/nobody');
      expect(find.text("This channel doesn't exist."), findsOneWidget);
    });
  });

  group('signed-in pages', () {
    testWidgets('signed out, Upload goes to Sign in and back afterwards', (
      tester,
    ) async {
      when(() => h.auth.login(any(), any())).thenAnswer((_) async => alice);
      await h.pump(tester, location: '/upload');
      expect(location(tester), '/signin?next=%2Fupload');
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Email'),
        'a@x.co',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'Passw0rd!',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Sign In'));
      await tester.pumpAndSettle();
      expect(location(tester), '/upload');
      expect(find.text('Drag and drop a video file to upload'), findsOneWidget);
    });

    testWidgets('Sign in while signed in goes home', (tester) async {
      await h.pump(tester, location: '/signin', user: alice);
      expect(location(tester), '/');
    });

    testWidgets('Your videos lists every status, with edit and delete', (
      tester,
    ) async {
      final items = [
        video(
          'r',
          'Still transcoding',
          creator: aliceCreator,
          status: VideoStatus.processing,
          visibility: VideoVisibility.public,
        ),
        video(
          'p',
          'Private video diary',
          creator: aliceCreator,
          status: VideoStatus.completed,
          visibility: VideoVisibility.private,
        ),
      ];
      when(
        () => h.videos.mine(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer((_) async => page(items));
      when(() => h.videos.progress('r')).thenAnswer(
        (_) async => const Progress(
          videoId: 'r',
          percent: 55,
          status: VideoStatus.processing,
        ),
      );
      when(() => h.videos.delete('p')).thenAnswer((_) async {});
      await h.pump(tester, location: '/my-videos', user: alice);
      expect(find.text('Still transcoding'), findsOneWidget);
      expect(find.text('Private video diary'), findsOneWidget);
      expect(find.text('Processing'), findsOneWidget);
      expect(find.text('Private'), findsOneWidget);

      await tester.pump(const Duration(seconds: 6));
      expect(find.text('55%'), findsOneWidget);

      await tester.tap(find.byTooltip('Delete').last);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(TextButton, 'DELETE'),
        ),
      );
      await tester.pumpAndSettle();
      verify(() => h.videos.delete('p')).called(1);
      expect(find.text('Private video diary'), findsNothing);
    });
  });
}
