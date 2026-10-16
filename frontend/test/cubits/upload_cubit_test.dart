import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ytp_app/core/api_exception.dart';
import 'package:ytp_app/cubits/upload_video/upload_video_cubit.dart';
import 'package:ytp_app/cubits/upload_video/upload_video_state.dart';
import 'package:ytp_app/models/saved_video.dart';
import 'package:ytp_app/models/video.dart';
import 'package:ytp_app/platform/browser.dart';
import 'package:ytp_app/services/upload_video_service.dart';

import 'helpers.dart';

const _video = PickedFile(
  name: 'clip.mp4',
  size: 1000,
  type: 'video/mp4',
  handle: 'video-blob',
);
const _thumb = PickedFile(
  name: 'thumbnail.jpg',
  size: 10,
  type: 'image/jpeg',
  handle: 'thumb-blob',
);
const _draft = UploadDraft(
  title: 'Clip',
  description: 'About it',
  visibility: VideoVisibility.unlisted,
  video: _video,
  thumbnail: _thumb,
);
const _saved = SavedVideo(
  id: 'v1',
  title: 'Clip',
  status: VideoStatus.pending,
  visibility: VideoVisibility.unlisted,
);

ApiException _code(String code, {int status = 400}) =>
    ApiException.fromResponse(status, <String, dynamic>{
      'code': code,
      'detail': 'detail for $code',
    });

const _network = ApiException(
  kind: ApiErrorKind.network,
  message: 'Upload interrupted.',
);

/// Records the leave-page warning; everything else is unused here.
class _Browser extends Fake implements Browser {
  final warnings = <bool>[];

  @override
  void setLeaveWarning(bool on) => warnings.add(on);

  @override
  ValueListenable<bool> get fullscreen => ValueNotifier(false);
}

void main() {
  late MockUploadService service;
  late _Browser browser;
  late List<UploadVideoState> states;

  setUpAll(() {
    registerFallbackValue(_video);
    registerFallbackValue(VideoVisibility.public);
  });

  UploadVideoCubit build() {
    final cubit = UploadVideoCubit(
      service,
      browser: browser,
      retryDelays: const [Duration.zero, Duration.zero],
    );
    cubit.stream.listen(states.add);
    return cubit;
  }

  void stubPut({
    required String contentType,
    Future<void> Function(UploadProgress? onProgress)? answer,
  }) {
    when(
      () => service.put(
        any(),
        any(),
        contentType,
        onProgress: any(named: 'onProgress'),
        cancel: any(named: 'cancel'),
      ),
    ).thenAnswer(
      (inv) =>
          answer?.call(inv.namedArguments[#onProgress] as UploadProgress?) ??
          Future.value(),
    );
  }

  void stubSave(Future<SavedVideo> Function() answer) => when(
    () => service.save(
      title: any(named: 'title'),
      description: any(named: 'description'),
      visibility: any(named: 'visibility'),
      videoKey: any(named: 'videoKey'),
      thumbnailKey: any(named: 'thumbnailKey'),
    ),
  ).thenAnswer((_) => answer());

  setUp(() {
    service = MockUploadService();
    browser = _Browser();
    states = [];
    when(() => service.thumbnailUrl()).thenAnswer(
      (_) async =>
          const PresignedUpload(url: 'https://s3/t', key: 'thumbnails/s/t'),
    );
    when(() => service.videoUrl()).thenAnswer(
      (_) async =>
          const PresignedUpload(url: 'https://s3/v', key: 'videos/s/v.mp4'),
    );
    stubPut(contentType: 'image/jpeg');
    stubPut(
      contentType: 'video/mp4',
      answer: (onProgress) async {
        onProgress?.call(500, 1000);
        onProgress?.call(1000, 1000);
      },
    );
    stubSave(() async => _saved);
  });

  test('happy path: thumbnail -> video (with progress) -> save', () async {
    final cubit = build();
    await cubit.upload(_draft);
    await Future<void>.delayed(Duration.zero);

    expect(states.first, const UploadVideoInProgress(UploadStage.thumbnail));
    expect(
      states,
      contains(
        const UploadVideoInProgress(
          UploadStage.video,
          sentBytes: 500,
          totalBytes: 1000,
        ),
      ),
    );
    expect(states.last, const UploadVideoSuccess(_saved));
    verify(
      () => service.put(
        'https://s3/t',
        _thumb,
        'image/jpeg',
        cancel: any(named: 'cancel'),
      ),
    ).called(1);
    verify(
      () => service.save(
        title: 'Clip',
        description: 'About it',
        visibility: VideoVisibility.unlisted,
        videoKey: 'videos/s/v.mp4',
        thumbnailKey: 'thumbnails/s/t',
      ),
    ).called(1);
    // Closing the tab asks first, only while the upload runs.
    expect(browser.warnings, [true, false]);
    await cubit.close();
  });

  test('already_saved (409) counts as success', () async {
    stubSave(() async => throw _code('already_saved', status: 409));
    final cubit = build();
    await cubit.upload(_draft);
    expect(cubit.state, isA<UploadVideoSuccess>());
    await cubit.close();
  });

  test('the video PUT retries on network errors', () async {
    var calls = 0;
    stubPut(
      contentType: 'video/mp4',
      answer: (_) async {
        if (++calls < 3) throw _network;
      },
    );
    final cubit = build();
    await cubit.upload(_draft);
    expect(calls, 3);
    expect(cubit.state, isA<UploadVideoSuccess>());
    await cubit.close();
  });

  test('403 fetches a fresh URL once and retries', () async {
    var calls = 0;
    stubPut(
      contentType: 'video/mp4',
      answer: (_) async {
        if (++calls == 1) throw _code('upload_forbidden', status: 403);
      },
    );
    final cubit = build();
    await cubit.upload(_draft);
    verify(() => service.videoUrl()).called(2);
    expect(cubit.state, isA<UploadVideoSuccess>());
    await cubit.close();
  });

  test('save failure -> error at saving; retry only re-saves', () async {
    var saves = 0;
    stubSave(() async {
      if (++saves == 1) {
        throw const ApiException(kind: ApiErrorKind.server, message: 'boom');
      }
      return _saved;
    });
    final cubit = build();
    await cubit.upload(_draft);
    expect(cubit.state, const UploadVideoError('boom', UploadStage.saving));

    await cubit.retry();
    expect(cubit.state, const UploadVideoSuccess(_saved));
    verify(() => service.thumbnailUrl()).called(1);
    verify(() => service.videoUrl()).called(1);
    await cubit.close();
  });

  test('invalid_s3_key on save is not retryable', () async {
    stubSave(() async => throw _code('invalid_s3_key'));
    final cubit = build();
    await cubit.upload(_draft);
    final state = cubit.state as UploadVideoError;
    expect(state.retryable, isFalse);
    expect(browser.warnings.last, isFalse);
    await cubit.close();
  });

  test('a failed thumbnail resumes from the thumbnail on retry', () async {
    var calls = 0;
    stubPut(
      contentType: 'image/jpeg',
      answer: (_) async {
        if (++calls == 1) throw _network;
      },
    );
    final cubit = build();
    await cubit.upload(_draft);
    expect(cubit.state, isA<UploadVideoError>());
    expect((cubit.state as UploadVideoError).stage, UploadStage.thumbnail);
    verifyNever(() => service.videoUrl());

    await cubit.retry();
    expect(cubit.state, isA<UploadVideoSuccess>());
    await cubit.close();
  });

  test('cancel aborts the transfer and saves nothing', () async {
    final started = Completer<void>();
    stubPut(
      contentType: 'video/mp4',
      answer: (_) async {
        started.complete();
        // The browser rejects the PUT once it is aborted.
        await Future<void>.delayed(const Duration(milliseconds: 10));
        throw const UploadAborted();
      },
    );
    final cubit = build();
    final upload = cubit.upload(_draft);
    await started.future;
    cubit.cancel();
    await upload;
    expect(cubit.state, const UploadVideoInitial());
    expect(cubit.draft, isNull);
    verifyNever(
      () => service.save(
        title: any(named: 'title'),
        description: any(named: 'description'),
        visibility: any(named: 'visibility'),
        videoKey: any(named: 'videoKey'),
        thumbnailKey: any(named: 'thumbnailKey'),
      ),
    );
    expect(browser.warnings.last, isFalse);
    await cubit.close();
  });

  test('UploadCancel aborts at once when already cancelled', () {
    var aborted = 0;
    final cancel = UploadCancel()..cancel();
    cancel.bind(() => aborted++);
    expect(aborted, 1);
    cancel.cancel();
    expect(aborted, 1);
  });
}
