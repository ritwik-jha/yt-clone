import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ytp_app/core/theme.dart';
import 'package:ytp_app/models/video.dart';
import 'package:ytp_app/widgets/edit_video_sheet.dart';
import 'package:ytp_app/widgets/video_card.dart';
import 'package:ytp_app/widgets/video_skeleton.dart';

import '../cubits/helpers.dart';

Widget _scaled(Widget child, {double scale = 2.0}) => MaterialApp(
  theme: buildDarkTheme(),
  builder: (context, c) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: c!,
  ),
  home: Scaffold(body: child),
);

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  testWidgets('VideoCard lays out at 200% text without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360 * 3, 800 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final v = makeVideo(
      'a',
      status: VideoStatus.processing,
      visibility: VideoVisibility.unlisted,
    );
    await tester.pumpWidget(
      _scaled(
        SingleChildScrollView(
          child: Column(
            children: [
              VideoCard(video: v, onTap: () {}),
              VideoCard(video: v, onTap: () {}, showOwnerInfo: true),
            ],
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('VideoCard exposes a button with a descriptive label', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final v = makeVideo('a', views: 1200);
    await tester.pumpWidget(
      _scaled(VideoCard(video: v, onTap: () {}), scale: 1),
    );
    expect(
      find.bySemanticsLabel(RegExp('Video a.*Ada.*1.2K views')),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('Edit sheet fits at 200% text', (tester) async {
    tester.view.physicalSize = const Size(360 * 3, 800 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _scaled(EditVideoSheet(video: makeVideo('a'), onSave: (_) async {})),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('skeleton announces loading and animates', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_scaled(const VideoListSkeleton(), scale: 1));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.bySemanticsLabel('Loading videos'), findsOneWidget);
    handle.dispose();
  });
}
