import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ytp_app/core/api_exception.dart';
import 'package:ytp_app/cubits/pending_uploads/pending_uploads_cubit.dart';
import 'package:ytp_app/cubits/upload_video/upload_video_cubit.dart';
import 'package:ytp_app/cubits/upload_video/upload_video_state.dart';
import 'package:ytp_app/models/saved_video.dart';
import 'package:ytp_app/models/upload_job.dart';
import 'package:ytp_app/models/video.dart';
import 'package:ytp_app/services/upload_job_store.dart';
import 'package:ytp_app/services/upload_video_service.dart';

import 'helpers.dart';

const _saved = SavedVideo(
  id: 'vid-1',
  title: 'T',
  status: VideoStatus.pending,
  visibility: VideoVisibility.private,
);

void _stubSave(MockUploadService s, {Object? error}) {
  final call = when(
    () => s.save(
      title: any(named: 'title'),
      description: any(named: 'description'),
      visibility: any(named: 'visibility'),
      videoKey: any(named: 'videoKey'),
      thumbnailKey: any(named: 'thumbnailKey'),
    ),
  );
  error == null ? call.thenAnswer((_) async => _saved) : call.thenThrow(error);
}

void main() {
  late MockUploadService service;
  late Directory tmp;
  late UploadJobStore store;
  late File video;
  late File thumb;

  setUpAll(() {
    registerFallbackValue(File('x'));
    registerFallbackValue(VideoVisibility.private);
  });

  setUp(() {
    service = MockUploadService();
    tmp = Directory.systemTemp.createTempSync('job_test');
    store = UploadJobStore(
      rootProvider: () async => Directory('${tmp.path}/uploads'),
    );
    video = File('${tmp.path}/in.mp4')..writeAsBytesSync(List.filled(100, 1));
    thumb = File('${tmp.path}/in.jpg')..writeAsBytesSync(List.filled(10, 2));

    when(() => service.thumbnailUrl()).thenAnswer(
      (_) async =>
          const PresignedUpload(url: 'https://s3/t', key: 'thumbs/t.jpg'),
    );
    when(() => service.videoUrl()).thenAnswer(
      (_) async => const PresignedUpload(
        url: 'https://s3/v?sig=secret',
        key: 'videos/u/v.mp4',
      ),
    );
    when(
      () => service.put(
        any(),
        any(),
        any(),
        onProgress: any(named: 'onProgress'),
        cancel: any(named: 'cancel'),
      ),
    ).thenAnswer((_) async {});
    _stubSave(service);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  UploadVideoCubit make() => UploadVideoCubit(
    service,
    store: store,
    retryDelays: const [Duration.zero],
  );

  Future<void> start(UploadVideoCubit c) => c.uploadVideo(
    title: 'T',
    description: 'd',
    visibility: VideoVisibility.private,
    video: video,
    thumbnail: thumb,
  );

  group('UploadJobStore', () {
    test('create copies the files; list/save/delete round-trip', () async {
      final job = await store.create(
        title: 'T',
        description: 'd',
        visibility: VideoVisibility.unlisted,
        video: video,
        thumbnail: thumb,
      );
      expect(job.video.existsSync(), isTrue);
      expect(job.video.path, isNot(video.path));
      job
        ..thumbnailUploaded = true
        ..thumbnailKey = 'thumbs/t.jpg';
      await store.save(job);

      final listed = await store.list();
      expect(listed, hasLength(1));
      expect(listed.single.thumbnailUploaded, isTrue);
      expect(listed.single.visibility, VideoVisibility.unlisted);

      await store.delete(job);
      expect(await store.list(), isEmpty);
    });

    test('never writes a presigned URL to disk', () async {
      final job = await store.create(
        title: 'T',
        description: '',
        visibility: VideoVisibility.private,
        video: video,
        thumbnail: thumb,
      );
      job.videoKey = 'videos/u/v.mp4';
      await store.save(job);
      final raw = File('${tmp.path}/uploads/${job.localId}/job.json')
          .readAsStringSync();
      expect(raw, isNot(contains('sig=')));
      expect(raw, isNot(contains('s3/v')));
      expect(jsonDecode(raw), isA<Map<String, dynamic>>());
    });

    test('a corrupt job.json is dropped', () async {
      final dir = Directory('${tmp.path}/uploads/bad')
        ..createSync(recursive: true);
      File('${dir.path}/job.json').writeAsStringSync('{not json');
      expect(await store.list(), isEmpty);
      expect(dir.existsSync(), isFalse);
    });
  });

  group('UploadVideoCubit with a store', () {
    test('success deletes the job and its copied files', () async {
      final cubit = make();
      await start(cubit);
      expect(cubit.state, isA<UploadVideoSuccess>());
      expect(await store.list(), isEmpty);
    });

    test('failure keeps the job, with progress persisted per stage', () async {
      _stubSave(
        service,
        error: const ApiException(
          kind: ApiErrorKind.unavailable,
          statusCode: 503,
          message: 'down',
        ),
      );
      final cubit = make();
      await start(cubit);
      expect(cubit.state, isA<UploadVideoError>());

      final jobs = await store.list();
      expect(jobs, hasLength(1));
      expect(jobs.single.thumbnailUploaded, isTrue);
      expect(jobs.single.videoUploaded, isTrue);
      expect(jobs.single.needsSave, isTrue);
    });

    test('a cancel discards the job', () async {
      when(
        () => service.put(
          'https://s3/v?sig=secret',
          any(),
          'video/mp4',
          onProgress: any(named: 'onProgress'),
          cancel: any(named: 'cancel'),
        ),
      ).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: '/'),
          type: DioExceptionType.cancel,
        ),
      );
      final cubit = make();
      await start(cubit);
      expect(cubit.state, isA<UploadVideoInitial>());
      expect(await store.list(), isEmpty);
    });

    test('resume skips finished stages (new process, job from disk)', () async {
      _stubSave(
        service,
        error: const ApiException(
          kind: ApiErrorKind.unavailable,
          statusCode: 503,
          message: 'down',
        ),
      );
      await start(make()); // "first run": everything uploads, save fails

      final job = (await store.list()).single;
      _stubSave(service);
      clearInteractions(service);

      final cubit = make(); // "second run"
      await cubit.resume(job);
      expect(cubit.state, isA<UploadVideoSuccess>());
      verifyNever(() => service.thumbnailUrl());
      verifyNever(() => service.videoUrl());
      expect(await store.list(), isEmpty);
    });

    test('resume of a half-uploaded video asks for a fresh URL', () async {
      final job = await store.create(
        title: 'T',
        description: '',
        visibility: VideoVisibility.private,
        video: video,
        thumbnail: thumb,
      );
      job
        ..thumbnailUploaded = true
        ..thumbnailKey = 'thumbs/t.jpg'
        ..videoKey = 'videos/u/old.mp4'; // key known, but no PUT finished
      await store.save(job);

      final cubit = make();
      await cubit.resume((await store.list()).single);
      verify(() => service.videoUrl()).called(1);
      verifyNever(() => service.thumbnailUrl());
      expect(cubit.state, isA<UploadVideoSuccess>());
    });

    test('missing local files -> non-retryable error, job removed', () async {
      final job = await store.create(
        title: 'T',
        description: '',
        visibility: VideoVisibility.private,
        video: video,
        thumbnail: thumb,
      );
      job.video.deleteSync();
      final cubit = make();
      await cubit.resume(job);
      expect(
        cubit.state,
        isA<UploadVideoError>().having((e) => e.retryable, 'retryable', false),
      );
      expect(await store.list(), isEmpty);
    });
  });

  group('PendingUploadsCubit', () {
    Future<UploadJob> job({
      bool uploaded = false,
      bool thumbDone = false,
    }) async {
      final j = await store.create(
        title: 'T${DateTime.now().microsecondsSinceEpoch}',
        description: '',
        visibility: VideoVisibility.private,
        video: video,
        thumbnail: thumb,
      );
      j
        ..thumbnailUploaded = thumbDone || uploaded
        ..thumbnailKey = (thumbDone || uploaded) ? 'thumbs/t.jpg' : null
        ..videoKey = uploaded ? 'videos/u/v.mp4' : null
        ..videoUploaded = uploaded;
      await store.save(j);
      return j;
    }

    test('uploaded-but-unsaved jobs are saved at once and removed', () async {
      await job(uploaded: true);
      final cubit = PendingUploadsCubit(store, service);
      await cubit.load();
      expect(cubit.state, isEmpty);
      expect(await store.list(), isEmpty);
      verify(
        () => service.save(
          title: any(named: 'title'),
          description: any(named: 'description'),
          visibility: any(named: 'visibility'),
          videoKey: 'videos/u/v.mp4',
          thumbnailKey: 'thumbs/t.jpg',
        ),
      ).called(1);
    });

    test('already_saved is treated as done', () async {
      await job(uploaded: true);
      _stubSave(
        service,
        error: ApiException.fromResponse(409, <String, dynamic>{
          'code': 'already_saved',
          'detail': 'x',
        }),
      );
      final cubit = PendingUploadsCubit(store, service);
      await cubit.load();
      expect(cubit.state, isEmpty);
    });

    test('a failed save keeps the job for the banner', () async {
      await job(uploaded: true);
      _stubSave(
        service,
        error: const ApiException(kind: ApiErrorKind.network, message: 'off'),
      );
      final cubit = PendingUploadsCubit(store, service);
      await cubit.load();
      expect(cubit.state, hasLength(1));
    });

    test(
      'other unfinished jobs show in the banner; discard removes them',
      () async {
        final j = await job(thumbDone: true);
        final cubit = PendingUploadsCubit(store, service);
        await cubit.load();
        expect(cubit.state.single.localId, j.localId);
        verifyNever(
          () => service.save(
            title: any(named: 'title'),
            description: any(named: 'description'),
            visibility: any(named: 'visibility'),
            videoKey: any(named: 'videoKey'),
            thumbnailKey: any(named: 'thumbnailKey'),
          ),
        );

        await cubit.discard(cubit.state.single);
        expect(cubit.state, isEmpty);
        expect(await store.list(), isEmpty);
      },
    );
  });
}
