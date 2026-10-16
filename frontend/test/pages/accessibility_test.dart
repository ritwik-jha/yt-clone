import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ytp_app/core/theme.dart';
import 'package:ytp_app/models/video.dart';
import 'package:ytp_app/widgets/edit_video_dialog.dart';

import 'harness.dart';

/// Browser font size at 200%, which Flutter web passes on as text scale.
Widget _scaled(Widget child) => MaterialApp(
  theme: buildDarkTheme(),
  builder: (context, c) => MediaQuery(
    data: MediaQuery.of(context)
        .copyWith(textScaler: const TextScaler.linear(2)),
    child: c!,
  ),
  home: Scaffold(body: child),
);

void main() {
  setUpAll(Harness.registerFallbacks);

  late Harness h;
  setUp(() {
    h = Harness()
      ..feed = [
        for (var i = 0; i < 6; i++)
          video(
            'v$i',
            'A long video title that wraps onto a second line $i',
            views: 1200 * i,
          ),
      ];
  });

  testWidgets('home grid lays out at 200% text without overflow', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await h.pump(tester, size: const Size(1280, 900));
    expect(tester.takeException(), isNull);
  });

  testWidgets('cards are links named after the video', (tester) async {
    final handle = tester.ensureSemantics();
    await h.pump(tester);
    expect(
      find.bySemanticsLabel(RegExp('A long video title .* 1')),
      findsWidgets,
    );
    expect(find.bySemanticsLabel('Video Stream home'), findsWidgets);
    handle.dispose();
  });

  testWidgets('edit dialog fits at 200% text', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1024, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _scaled(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showEditVideoDialog(
              context,
              video: video('a', 'Title', visibility: VideoVisibility.public),
              onSave: (_) async {},
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Video details'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('player controls are labelled for screen readers', (
    tester,
  ) async {
    when(() => h.videos.detail('v1')).thenAnswer(
      (_) async => video('v1', 'Clip', status: VideoStatus.completed),
    );
    when(() => h.videos.recordView(any())).thenAnswer((_) async {});
    final handle = tester.ensureSemantics();
    await h.pump(tester, location: '/watch?v=v1');
    expect(find.byTooltip('Pause (k)'), findsOneWidget);
    expect(find.byTooltip('Mute (m)'), findsOneWidget);
    expect(find.byTooltip('Full screen (f)'), findsOneWidget);
    expect(find.bySemanticsLabel('Seek'), findsOneWidget);
    handle.dispose();
  });
}
