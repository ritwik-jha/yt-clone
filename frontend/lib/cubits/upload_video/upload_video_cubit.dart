import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/api_exception.dart';
import '../../models/saved_video.dart';
import '../../models/video.dart';
import '../../services/upload_video_service.dart';
import 'upload_video_state.dart';

/// Uploads thumbnail -> video -> save, resuming from the stage that failed
/// on retry (plan §7).
class UploadVideoCubit extends Cubit<UploadVideoState> {
  UploadVideoCubit(
    this._service, {
    this.retryDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 3),
      Duration(seconds: 8),
    ],
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now,
       super(const UploadVideoInitial());

  final UploadVideoService _service;
  final List<Duration> retryDelays;
  final DateTime Function() _now;

  static const _urlLifetime = Duration(minutes: 55);

  // Job state kept across retries.
  _Job? _job;
  CancelToken? _cancel;

  Future<void> uploadVideo({
    required String title,
    required String description,
    required VideoVisibility visibility,
    required File video,
    required File thumbnail,
  }) async {
    _job = _Job(
      title: title,
      description: description,
      visibility: visibility,
      video: video,
      thumbnail: thumbnail,
    );
    await _run();
  }

  Future<void> retry() async {
    if (_job == null) return;
    await _run();
  }

  void cancel() {
    _cancel?.cancel('cancelled');
  }

  void reset() {
    _job = null;
    emit(const UploadVideoInitial());
  }

  Future<void> _run() async {
    final job = _job!;
    _cancel = CancelToken();
    var stage = UploadStage.thumbnail;
    try {
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
      }

      if (!job.videoUploaded) {
        stage = UploadStage.video;
        await _uploadVideo(job);
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
        _job = null;
        emit(UploadVideoSuccess(saved));
      } on ApiException catch (e) {
        if (e.code == 'already_saved') {
          // The save already went through; My Videos will show it.
          _job = null;
          emit(UploadVideoSuccess(_alreadySaved(job)));
        } else {
          rethrow;
        }
      }
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        _job = null;
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

  Future<void> _uploadVideo(_Job job) async {
    var attempt = 0;
    var forbiddenRetried = false;
    while (true) {
      final fresh =
          job.videoUrl != null &&
          job.videoUrlIssuedAt != null &&
          _now().difference(job.videoUrlIssuedAt!) < _urlLifetime;
      if (!fresh) {
        emit(const UploadVideoInProgress(UploadStage.video));
        final target = await _service.videoUrl();
        job
          ..videoUrl = target.url
          ..videoKey = target.key
          ..videoUrlIssuedAt = _now();
      }

      final total = await job.video.length();
      emit(UploadVideoInProgress(UploadStage.video, totalBytes: total));
      try {
        await _service.put(
          job.videoUrl!,
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
          job.videoUrl = null;
          continue;
        }
        if (e.code == 'upload_forbidden' || attempt >= retryDelays.length) {
          rethrow;
        }
        await Future<void>.delayed(retryDelays[attempt++]);
      }
    }
  }

  SavedVideo _alreadySaved(_Job job) => SavedVideo(
    id: '',
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

class _Job {
  _Job({
    required this.title,
    required this.description,
    required this.visibility,
    required this.video,
    required this.thumbnail,
  });

  final String title;
  final String description;
  final VideoVisibility visibility;
  final File video;
  final File thumbnail;

  String? thumbnailKey;
  bool thumbnailUploaded = false;
  String? videoKey;
  String? videoUrl;
  DateTime? videoUrlIssuedAt;
  bool videoUploaded = false;
}
