import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ytp_app/models/saved_video.dart';
import 'package:ytp_app/models/video.dart';
import 'package:ytp_app/platform/browser.dart';
import 'package:ytp_app/services/upload_video_service.dart';

import 'harness.dart';

const _clip = PickedFile(
  name: 'Sunset at the beach.mp4',
  size: 5 << 20,
  type: 'video/mp4',
  handle: 'video',
);
const _frame = PickedFile(
  name: 'thumbnail.jpg',
  size: 1,
  type: 'image/jpeg',
  handle: 'frame',
);

void main() {
  setUpAll(() {
    Harness.registerFallbacks();
    registerFallbackValue(_clip);
    registerFallbackValue(VideoVisibility.public);
  });

  late Harness h;
  setUp(() {
    h = Harness();
    when(() => h.uploads.thumbnailUrl()).thenAnswer(
      (_) async =>
          const PresignedUpload(url: 'https://s3/t', key: 'thumbnails/s/t'),
    );
    when(() => h.uploads.videoUrl()).thenAnswer(
      (_) async =>
          const PresignedUpload(url: 'https://s3/v', key: 'videos/s/v.mp4'),
    );
    when(
      () => h.uploads.put(
        any(),
        any(),
        any(),
        onProgress: any(named: 'onProgress'),
        cancel: any(named: 'cancel'),
      ),
    ).thenAnswer((_) async {});
    when(
      () => h.uploads.save(
        title: any(named: 'title'),
        description: any(named: 'description'),
        visibility: any(named: 'visibility'),
        videoKey: any(named: 'videoKey'),
        thumbnailKey: any(named: 'thumbnailKey'),
      ),
    ).thenAnswer(
      (_) async => const SavedVideo(
        id: 'v1',
        title: 'Sunset at the beach',
        status: VideoStatus.pending,
        visibility: VideoVisibility.unlisted,
      ),
    );
  });

  testWidgets('pick a file, fill in details, upload', (tester) async {
    h.browser
      ..picks.add(_clip)
      ..frame = _frame;
    await h.pump(tester, location: '/upload', user: alice);
    await tester.tap(find.text('SELECT FILE'));
    await tester.pumpAndSettle();

    // Title from the file name; the captured frame is the thumbnail.
    expect(
      find.widgetWithText(TextFormField, 'Sunset at the beach'),
      findsOneWidget,
    );
    expect(find.text('5.0 MB'), findsOneWidget);
    expect(find.text('CHANGE THUMBNAIL'), findsOneWidget);
    await tester.tap(find.text('Unlisted'));
    await tester.tap(find.text('UPLOAD'));
    await tester.pumpAndSettle();

    verify(
      () => h.uploads.put(
        'https://s3/t',
        _frame,
        'image/jpeg',
        cancel: any(named: 'cancel'),
      ),
    ).called(1);
    verify(
      () => h.uploads.put(
        'https://s3/v',
        _clip,
        'video/mp4',
        onProgress: any(named: 'onProgress'),
        cancel: any(named: 'cancel'),
      ),
    ).called(1);
    verify(
      () => h.uploads.save(
        title: 'Sunset at the beach',
        description: '',
        visibility: VideoVisibility.unlisted,
        videoKey: 'videos/s/v.mp4',
        thumbnailKey: 'thumbnails/s/t',
      ),
    ).called(1);
    expect(find.text('Upload complete'), findsOneWidget);
    expect(h.browser.warnings, [true, false]);

    when(
      () => h.videos.mine(
        page: any(named: 'page'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer((_) async => page([]));
    await tester.tap(find.text('GO TO YOUR VIDEOS'));
    await tester.pumpAndSettle();
    expect(location(tester), '/my-videos');
  });

  testWidgets('a file that is not an MP4 is refused', (tester) async {
    h.browser.picks.add(
      const PickedFile(
        name: 'notes.txt',
        size: 10,
        type: 'text/plain',
        handle: 0,
      ),
    );
    await h.pump(tester, location: '/upload', user: alice);
    await tester.tap(find.text('SELECT FILE'));
    await tester.pumpAndSettle();
    expect(find.text('Choose an MP4 video file.'), findsOneWidget);
    expect(find.text('UPLOAD'), findsNothing);
  });

  testWidgets('no frame from the video: an image is required', (tester) async {
    h.browser
      ..picks.addAll([
        _clip,
        const PickedFile(
          name: 'cover.png',
          size: 1,
          type: 'image/png',
          handle: 'png',
        ),
      ])
      ..frame = null;
    await h.pump(tester, location: '/upload', user: alice);
    await tester.tap(find.text('SELECT FILE'));
    await tester.pumpAndSettle();
    expect(find.textContaining("Couldn't take a thumbnail"), findsOneWidget);

    await tester.tap(find.text('UPLOAD'));
    await tester.pumpAndSettle();
    expect(find.text('Add a thumbnail.'), findsOneWidget);

    await tester.tap(find.text('UPLOAD THUMBNAIL'));
    await tester.pumpAndSettle();
    expect(find.text('CHANGE THUMBNAIL'), findsOneWidget);
    await tester.tap(find.text('UPLOAD'));
    await tester.pumpAndSettle();
    expect(find.text('Upload complete'), findsOneWidget);
  });
}
