import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ytp_app/app/app.dart';
import 'package:ytp_app/core/api_exception.dart';
import 'package:ytp_app/models/channel.dart';
import 'package:ytp_app/models/page_result.dart';
import 'package:ytp_app/models/user_profile.dart';
import 'package:ytp_app/models/video.dart';
import 'package:ytp_app/models/watch_progress.dart';
import 'package:ytp_app/platform/browser.dart';
import 'package:ytp_app/platform/video_stub.dart';
import 'package:ytp_app/services/video_service.dart';

import '../cubits/helpers.dart';

const alice = UserProfile(id: 'alice', name: 'Alice Tester', email: 'a@x.co');
const bob = Creator(id: 'bob', name: 'Bob Tester');
const aliceCreator = Creator(id: 'alice', name: 'Alice Tester');

Video video(
  String id,
  String title, {
  Creator creator = bob,
  int views = 0,
  VideoStatus? status,
  VideoVisibility? visibility,
  String? description,
}) => Video(
  id: id,
  title: title,
  description: description,
  thumbnailUrl: '',
  hlsUrl: 'https://cdn/$id/master.m3u8',
  manifestUrl: 'https://cdn/$id/manifest.mpd',
  viewsCount: views,
  durationSeconds: 61,
  creator: creator,
  createdAt: DateTime(2026, 1, 1),
  status: status,
  visibility: visibility,
);

PageResult<Video> page(List<Video> items) =>
    PageResult(total: items.length, page: 1, limit: 24, items: items);

final unauthorized = ApiException.fromResponse(401, <String, dynamic>{
  'code': 'missing_access_token',
  'detail': 'Missing access token',
});

/// A scriptable [Browser]: [picks] answers file choosers in order,
/// [storage] is its localStorage, [hide] and [show] play the tab's
/// visibility, and [exitPosts] records keepalive POSTs.
class FakeBrowser implements Browser {
  final picks = <PickedFile?>[];
  final warnings = <bool>[];
  PickedFile? frame;
  final _fullscreen = ValueNotifier(false);
  final storage = <String, String>{};
  final exitPosts = <(String url, String json)>[];
  final _visibility = <(void Function(), void Function())>[];

  void hide() {
    for (final (onHidden, _) in [..._visibility]) {
      onHidden();
    }
  }

  void show() {
    for (final (_, onVisible) in [..._visibility]) {
      onVisible();
    }
  }

  @override
  String? readLocal(String key) => storage[key];

  @override
  void writeLocal(String key, String value) => storage[key] = value;

  @override
  void removeLocal(String key) => storage.remove(key);

  @override
  List<String> localKeys(String prefix) => [
    for (final k in storage.keys)
      if (k.startsWith(prefix)) k,
  ];

  @override
  void Function() listenForVisibility({
    required void Function() onHidden,
    required void Function() onVisible,
  }) {
    final entry = (onHidden, onVisible);
    _visibility.add(entry);
    return () => _visibility.remove(entry);
  }

  @override
  void postOnExit(String url, String json) => exitPosts.add((url, json));

  @override
  ValueListenable<bool> get fullscreen => _fullscreen;

  @override
  Future<void> setFullscreen(bool on) async => _fullscreen.value = on;

  @override
  Future<PickedFile?> pickFile({required String accept}) async =>
      picks.isEmpty ? null : picks.removeAt(0);

  @override
  void Function() listenForDrops(void Function(PickedFile file) onFile) =>
      () {};

  @override
  Future<PickedFile?> captureFrame(PickedFile video) async => frame;

  @override
  Future<PickedFile?> toJpeg(PickedFile image) async => PickedFile(
    name: 'thumbnail.jpg',
    size: 1,
    type: 'image/jpeg',
    handle: image.handle,
  );

  @override
  String objectUrl(PickedFile file) => '';

  @override
  void revokeUrl(String url) {}

  @override
  Future<void> put(
    String url,
    PickedFile file, {
    required String contentType,
    UploadProgress? onProgress,
    UploadCancel? cancel,
  }) async {}

  @override
  void setLeaveWarning(bool on) => warnings.add(on);
}

/// The whole app (router, shell, pages) over mocked services.
class Harness {
  final auth = MockAuthService();
  final videos = MockVideoService();
  final uploads = MockUploadService();
  final history = MockHistoryService();
  final browser = FakeBrowser();
  final players = <StubPlayerController>[];

  /// Public feed, newest first.
  List<Video> feed = [];

  /// Channel ids that answer `channel_not_found`.
  final missingChannels = <String>{};

  /// The signed-in user's history: what `positions` and `list` answer.
  final watched = <String, WatchProgress>{};

  static void registerFallbacks() {
    registerFallbackValue(VideoSort.latest);
    registerFallbackValue(const VideoUpdate());
    registerFallbackValue(<ProgressReport>[]);
  }

  /// Every report is saved; positions and the list come from [watched].
  void stubHistory() {
    when(() => history.exitUrl).thenReturn('http://api.test/history/progress');
    when(() => history.record(any())).thenAnswer(
      (inv) async => [
        for (final r in inv.positionalArguments.first as List<ProgressReport>)
          ProgressResult(
            videoId: r.videoId,
            outcome: ProgressOutcome.saved,
            progress: WatchProgress.fromReport(r),
          ),
      ],
    );
    when(() => history.positions(any())).thenAnswer(
      (inv) async => [
        for (final id in inv.positionalArguments.first as List<String>)
          ?watched[id],
      ],
    );
    when(
      () => history.list(
        cursor: any(named: 'cursor'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer((_) async {
      final entries =
          [
            for (final p in watched.values)
              for (final v in feed)
                if (v.id == p.videoId) HistoryEntry(video: v, progress: p),
          ]..sort(
            (a, b) =>
                b.progress.lastWatchedAt.compareTo(a.progress.lastWatchedAt),
          );
      return HistoryPage(items: entries);
    });
    when(() => history.remove(any())).thenAnswer((_) async {});
    when(() => history.clear()).thenAnswer((_) async {});
  }

  void stubFeed() {
    when(
      () => videos.feed(
        page: any(named: 'page'),
        limit: any(named: 'limit'),
        sort: any(named: 'sort'),
      ),
    ).thenAnswer((inv) async {
      final sort = inv.namedArguments[#sort] as VideoSort;
      final items = [...feed];
      if (sort == VideoSort.popular) {
        items.sort((a, b) => b.viewsCount.compareTo(a.viewsCount));
      }
      return page(items);
    });
    when(
      () => videos.channel(
        any(),
        page: any(named: 'page'),
        limit: any(named: 'limit'),
        sort: any(named: 'sort'),
      ),
    ).thenAnswer((inv) async {
      final id = inv.positionalArguments.first as String;
      if (missingChannels.contains(id)) {
        throw ApiException.fromResponse(404, <String, dynamic>{
          'code': 'channel_not_found',
          'detail': 'Channel not found',
        });
      }
      final mine = feed.where((v) => v.creator.id == id).toList();
      final creator = mine.isEmpty
          ? Creator(id: id, name: 'Nobody', createdAt: DateTime(2025, 6, 1))
          : Creator(
              id: id,
              name: mine.first.creator.name,
              createdAt: DateTime(2025, 6, 1),
            );
      return ChannelListing(creator: creator, videos: page(mine));
    });
  }

  Future<void> pump(
    WidgetTester tester, {
    String location = '/',
    UserProfile? user,
    Size size = const Size(1440, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    if (user == null) {
      when(() => auth.me()).thenThrow(unauthorized);
    } else {
      when(() => auth.me()).thenAnswer((_) async => user);
    }
    stubFeed();
    stubHistory();
    await tester.pumpWidget(
      YtpApp(
        apiBaseUrl: 'http://api.test',
        auth: auth,
        videos: videos,
        uploads: uploads,
        history: history,
        browser: browser,
        players: PlayerFactory(() {
          final p = StubPlayerController();
          players.add(p);
          return p;
        }),
        initialLocation: location,
      ),
    );
    await settle(tester);
  }
}

/// [WidgetTester.pumpAndSettle], then once more for timers that the last
/// frame started (the progress bars batch their lookups on a zero timer).
Future<void> settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.pump();
  await tester.pumpAndSettle();
}

/// The current URL of the app under test.
String location(WidgetTester tester) {
  final context = tester.element(find.byType(Navigator).first);
  return Router.of(context).routeInformationProvider!.value.uri.toString();
}
