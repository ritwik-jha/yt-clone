import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/api_exception.dart';
import '../../models/saved_video.dart';
import '../../models/upload_job.dart';
import '../../models/video.dart';
import '../../services/upload_job_store.dart';
import '../../services/upload_video_service.dart';
import 'upload_video_state.dart';

/// Uploads thumbnail -> video -> save, resuming from the stage that failed
/// on retry (plan §7). With a [UploadJobStore] the job is persisted after
/// every stage, so a killed app can resume it on the next launch (§7.5).
class UploadVideoCubit extends Cubit<UploadVideoState> {
  UploadVideoCubit(
    this._service, {
    this._store,
    this.retryDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 3),
      Duration(seconds: 8),
    ],
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now,
       super(const UploadVideoInitial());

  final UploadVideoService _service;
  final UploadJobStore? _store;
  final List<Duration> retryDelays;
  final DateTime Function() _now;

  static const _urlLifetime = Duration(minutes: 55);

  UploadJob? _job;
  CancelToken? _cancel;

  // The presigned video URL is a credential, so it lives in memory only.
  String? _videoUrl;
  DateTime? _videoUrlIssuedAt;

  Future<void> uploadVideo({
    required String title,
    required String description,
    required VideoVisibility visibility,
    required File video,
    required File thumbnail,
  }) async {
    final store = _store;
    _job = store != null
        ? await store.create(
            title: title,
            description: description,
            visibility: visibility,
            video: video,
            thumbnail: thumbnail,
          )
        : UploadJob(
            localId: 'memory',
            title: title,
            description: description,
            visibility: visibility,
            videoPath: video.path,
            thumbnailPath: thumbnail.path,
          );
    await _run();
  }

  /// Continues a job loaded from disk.
  Future<void> resume(UploadJob job) async {
    _job = job;
    await _run();
  }

  Future<void> retry() async {
    if (_job == null) return;
    await _run();
  }

  /// Stops the transfer and discards the job: a user cancel saves nothing.
  void cancel() {
    _cancel?.cancel('cancelled');
  }

  void reset() {
    _job = null;
    emit(const UploadVideoInitial());
  }

  Future<void> _persist() async => _store?.save(_job!);

  Future<void> _finish() async {
    final job = _job;
    _job = null;
    if (job != null) await _store?.delete(job);
  }

  Future<void> _run() async {
    final job = _job!;
    _cancel = CancelToken();
    var stage = UploadStage.thumbnail;
    try {
      if (!await job.video.exists() || !await job.thumbnail.exists()) {
        await _finish();
        emit(
          const UploadVideoError(
            'The selected files are no longer available. Please upload again.',
            UploadStage.thumbnail,
            retryable: false,
          ),
        );
        return;
      }

      if (!job.thumbnailUploaded) {
        stage = UploadStage.thumbnail;
        emit(const UploadVideoInProgress(UploadStage.thumbnail));
        final target = await _service.thumbnailUrl();
        await _service.put(
          target.url,
          job.thumbnail,
          'image/jpeg',
          cancel: _cancel,
        );
        job
          ..thumbnailKey = target.key
          ..thumbnailUploaded = true;
        await _persist();
      }

      if (!job.videoUploaded) {
        stage = UploadStage.video;
        await _uploadVideo(job);
        await _persist();
      }

      stage = UploadStage.saving;
      emit(const UploadVideoInProgress(UploadStage.saving));
      try {
        final saved = await _service.save(
          title: job.title,
          description: job.description,
          visibility: job.visibility,
          videoKey: job.videoKey!,
          thumbnailKey: job.thumbnailKey!,
        );
        await _finish();
        emit(UploadVideoSuccess(saved));
      } on ApiException catch (e) {
        if (e.code == 'already_saved') {
          // The save already went through; My Videos will show it.
          await _finish();
          emit(UploadVideoSuccess(_alreadySaved(job)));
        } else {
          rethrow;
        }
      }
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        await _finish();
        emit(const UploadVideoInitial());
      } else {
        emit(UploadVideoError(ApiException.fromDio(e).message, stage));
      }
    } on ApiException catch (e) {
      final clientBug =
          stage == UploadStage.saving &&
          (e.code == 'invalid_s3_key' ||
              e.code == 'invalid_thumbnail_key' ||
              e.code == 'validation_error');
      emit(UploadVideoError(e.message, stage, retryable: !clientBug));
    }
  }

  Future<void> _uploadVideo(UploadJob job) async {
    var attempt = 0;
    var forbiddenRetried = false;
    while (true) {
      final fresh =
          _videoUrl != null &&
          _videoUrlIssuedAt != null &&
          job.videoKey != null &&
          _now().difference(_videoUrlIssuedAt!) < _urlLifetime;
      if (!fresh) {
        emit(const UploadVideoInProgress(UploadStage.video));
        final target = await _service.videoUrl();
        _videoUrl = target.url;
        job.videoKey = target.key;
        _videoUrlIssuedAt = _now();
        await _persist();
      }

      final total = await job.video.length();
      emit(UploadVideoInProgress(UploadStage.video, totalBytes: total));
      try {
        await _service.put(
          _videoUrl!,
          job.video,
          'video/mp4',
          cancel: _cancel,
          onProgress: (sent, t) => emit(
            UploadVideoInProgress(
              UploadStage.video,
              sentBytes: sent,
              totalBytes: t > 0 ? t : total,
            ),
          ),
        );
        job.videoUploaded = true;
        return;
      } on ApiException catch (e) {
        if (e.code == 'upload_forbidden' && !forbiddenRetried) {
          // The URL expired or its signature didn't match: fetch a new one.
          forbiddenRetried = true;
          _videoUrl = null;
          continue;
        }
        if (e.code == 'upload_forbidden' || attempt >= retryDelays.length) {
          rethrow;
        }
        await Future<void>.delayed(retryDelays[attempt++]);
      }
    }
  }

  SavedVideo _alreadySaved(UploadJob job) => SavedVideo(
    id: job.savedVideoId ?? '',
    title: job.title,
    status: VideoStatus.pending,
    visibility: job.visibility,
  );

  @override
  Future<void> close() {
    _cancel?.cancel('closed');
    return super.close();
  }
}
