import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ytp_app/core/api_exception.dart';
import 'package:ytp_app/cubits/upload_video/upload_video_cubit.dart';
import 'package:ytp_app/cubits/upload_video/upload_video_state.dart';
import 'package:ytp_app/models/saved_video.dart';
import 'package:ytp_app/models/video.dart';
import 'package:ytp_app/services/upload_video_service.dart';

import 'helpers.dart';

const _saved = SavedVideo(
  id: 'vid-1',
  title: 'T',
  status: VideoStatus.pending,
  visibility: VideoVisibility.private,
);

ApiException _err(String code, {int status = 400}) => ApiException.fromResponse(
  status,
  <String, dynamic>{'code': code, 'detail': code},
);

void main() {
  late MockUploadService service;
  late Directory tmp;
  late File video;
  late File thumb;

  setUpAll(() {
    registerFallbackValue(File('x'));
    registerFallbackValue(VideoVisibility.private);
  });

  setUp(() {
    service = MockUploadService();
    tmp = Directory.systemTemp.createTempSync('upload_test');
    video = File('${tmp.path}/v.mp4')..writeAsBytesSync(List.filled(100, 1));
    thumb = File('${tmp.path}/t.jpg')..writeAsBytesSync(List.filled(10, 2));

    when(() => service.thumbnailUrl()).thenAnswer(
      (_) async =>
          const PresignedUpload(url: 'https://s3/t', key: 'thumbs/t.jpg'),
    );
    when(() => service.videoUrl()).thenAnswer(
      (_) async =>
          const PresignedUpload(url: 'https://s3/v', key: 'videos/u/v.mp4'),
    );
    when(
      () => service.put(
        any(),
        any(),
        any(),
        onProgress: any(named: 'onProgress'),
        cancel: any(named: 'cancel'),
      ),
    ).thenAnswer((inv) async {
      final cb = inv.namedArguments[#onProgress] as ProgressCallback?;
      cb?.call(50, 100);
    });
    when(
      () => service.save(
        title: any(named: 'title'),
        description: any(named: 'description'),
        visibility: any(named: 'visibility'),
        videoKey: any(named: 'videoKey'),
        thumbnailKey: any(named: 'thumbnailKey'),
      ),
    ).thenAnswer((_) async => _saved);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  UploadVideoCubit make() => UploadVideoCubit(
    service,
    retryDelays: const [Duration.zero, Duration.zero, Duration.zero],
  );

  Future<void> run(UploadVideoCubit c) => c.uploadVideo(
    title: 'T',
    description: '',
    visibility: VideoVisibility.private,
    video: video,
    thumbnail: thumb,
  );

  test('happy path: thumbnail -> video (with progress) -> save', () async {
    final cubit = make();
    final stages = <UploadStage>[];
    cubit.stream.listen((s) {
      if (s is UploadVideoInProgress && !stages.contains(s.stage)) {
        stages.add(s.stage);
      }
    });
    await run(cubit);
    await Future<void>.delayed(Duration.zero); // let stream events flush
    expect(cubit.state, isA<UploadVideoSuccess>());
    expect(stages, [
      UploadStage.thumbnail,
      UploadStage.video,
      UploadStage.saving,
    ]);
    verify(
      () => service.put(
        'https://s3/t',
        thumb,
        'image/jpeg',
        cancel: any(named: 'cancel'),
      ),
    ).called(1);
    verify(
      () => service.put(
        'https://s3/v',
        video,
        'video/mp4',
        onProgress: any(named: 'onProgress'),
        cancel: any(named: 'cancel'),
      ),
    ).called(1);
  });

  test('already_saved (409) counts as success', () async {
    when(
      () => service.save(
        title: any(named: 'title'),
        description: any(named: 'description'),
        visibility: any(named: 'visibility'),
        videoKey: any(named: 'videoKey'),
        thumbnailKey: any(named: 'thumbnailKey'),
      ),
    ).thenThrow(_err('already_saved', status: 409));
    final cubit = make();
    await run(cubit);
    expect(cubit.state, isA<UploadVideoSuccess>());
  });

  test('video PUT retries automatically on network errors', () async {
    var puts = 0;
    when(
      () => service.put(
        'https://s3/v',
        any(),
        'video/mp4',
        onProgress: any(named: 'onProgress'),
        cancel: any(named: 'cancel'),
      ),
    ).thenAnswer((_) async {
      if (++puts < 3) {
        throw const ApiException(kind: ApiErrorKind.network, message: 'drop');
      }
    });
    final cubit = make();
    await run(cubit);
    expect(puts, 3);
    expect(cubit.state, isA<UploadVideoSuccess>());
  });

  test('403 fetches a fresh URL once and retries', () async {
    var puts = 0;
    when(
      () => service.put(
        any(that: startsWith('https://s3/v')),
        any(),
        'video/mp4',
        onProgress: any(named: 'onProgress'),
        cancel: any(named: 'cancel'),
      ),
    ).thenAnswer((_) async {
      if (++puts == 1) throw _err('upload_forbidden', status: 403);
    });
    final cubit = make();
    await run(cubit);
    verify(() => service.videoUrl()).called(2);
    expect(cubit.state, isA<UploadVideoSuccess>());
  });

  test('save failure -> error at saving; retry only re-saves', () async {
    var saves = 0;
    when(
      () => service.save(
        title: any(named: 'title'),
        description: any(named: 'description'),
        visibility: any(named: 'visibility'),
        videoKey: any(named: 'videoKey'),
        thumbnailKey: any(named: 'thumbnailKey'),
      ),
    ).thenAnswer((_) async {
      if (++saves == 1) {
        throw const ApiException(
          kind: ApiErrorKind.unavailable,
          statusCode: 503,
          message: 'down',
        );
      }
      return _saved;
    });
    final cubit = make();
    await run(cubit);
    expect(
      cubit.state,
      isA<UploadVideoError>().having(
        (e) => e.stage,
        'stage',
        UploadStage.saving,
      ),
    );

    await cubit.retry();
    expect(cubit.state, isA<UploadVideoSuccess>());
    verify(() => service.thumbnailUrl()).called(1); // never re-uploaded
    verify(() => service.videoUrl()).called(1);
  });

  test('invalid_s3_key on save is a non-retryable error', () async {
    when(
      () => service.save(
        title: any(named: 'title'),
        description: any(named: 'description'),
        visibility: any(named: 'visibility'),
        videoKey: any(named: 'videoKey'),
        thumbnailKey: any(named: 'thumbnailKey'),
      ),
    ).thenThrow(_err('invalid_s3_key'));
    final cubit = make();
    await run(cubit);
    expect(
      cubit.state,
      isA<UploadVideoError>().having((e) => e.retryable, 'retryable', false),
    );
  });

  test('thumbnail failure resumes from the thumbnail on retry', () async {
    var calls = 0;
    when(() => service.thumbnailUrl()).thenAnswer((_) async {
      if (++calls == 1) {
        throw const ApiException(
          kind: ApiErrorKind.network,
          message: 'offline',
        );
      }
      return const PresignedUpload(url: 'https://s3/t', key: 'thumbs/t.jpg');
    });
    final cubit = make();
    await run(cubit);
    expect(
      cubit.state,
      isA<UploadVideoError>().having(
        (e) => e.stage,
        'stage',
        UploadStage.thumbnail,
      ),
    );
    await cubit.retry();
    expect(cubit.state, isA<UploadVideoSuccess>());
  });
}
