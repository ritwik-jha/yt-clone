import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/api_exception.dart';
import '../../models/saved_video.dart';
import '../../models/video.dart';
import '../../platform/browser.dart';
import '../../services/upload_video_service.dart';
import 'upload_video_state.dart';

/// What the user chose to upload.
class UploadDraft {
  const UploadDraft({
    required this.title,
    required this.description,
    required this.visibility,
    required this.video,
    required this.thumbnail,
  });

  final String title;
  final String description;
  final VideoVisibility visibility;
  final PickedFile video;

  /// A JPEG: a frame captured from [video], or an image the user picked.
  final PickedFile thumbnail;
}

/// Uploads thumbnail -> video -> save, resuming from the stage that failed
/// on retry (plan §7). Lives at the app root, so an upload keeps going while
/// the user browses; the tab asks before closing while one is running.
class UploadVideoCubit extends Cubit<UploadVideoState> {
  UploadVideoCubit(
    this._service, {
    this._browser,
    this.retryDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 3),
      Duration(seconds: 8),
    ],
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now,
       super(const UploadVideoInitial());

  final UploadVideoService _service;
  final Browser? _browser;
  final List<Duration> retryDelays;
  final DateTime Function() _now;

  static const _urlLifetime = Duration(minutes: 55);

  UploadDraft? _draft;
  String? _thumbnailKey;
  String? _videoKey;
  bool _videoUploaded = false;
  UploadCancel? _cancel;

  // The presigned video URL is a credential, so it lives in memory only.
  String? _videoUrl;
  DateTime? _videoUrlIssuedAt;

  /// The upload in progress, failed, or just finished.
  UploadDraft? get draft => _draft;

  Future<void> upload(UploadDraft draft) async {
    _draft = draft;
    _thumbnailKey = null;
    _videoKey = null;
    _videoUploaded = false;
    _videoUrl = null;
    await _run();
  }

  Future<void> retry() async {
    if (_draft == null) return;
    await _run();
  }

  /// Stops the transfer and discards the upload: a cancel saves nothing.
  void cancel() {
    _cancel?.cancel();
    if (state is UploadVideoError) reset();
  }

  void reset() {
    _draft = null;
    _browser?.setLeaveWarning(false);
    emit(const UploadVideoInitial());
  }

  Future<void> _run() async {
    final draft = _draft!;
    final cancel = _cancel = UploadCancel();
    _browser?.setLeaveWarning(true);
    var stage = UploadStage.thumbnail;
    try {
      if (_thumbnailKey == null) {
        emit(const UploadVideoInProgress(UploadStage.thumbnail));
        final target = await _service.thumbnailUrl();
        await _service.put(
          target.url,
          draft.thumbnail,
          'image/jpeg',
          cancel: cancel,
        );
        _thumbnailKey = target.key;
      }

      if (!_videoUploaded) {
        stage = UploadStage.video;
        await _uploadVideo(draft, cancel);
      }

      stage = UploadStage.saving;
      if (cancel.isCancelled) throw const UploadAborted();
      emit(const UploadVideoInProgress(UploadStage.saving));
      SavedVideo saved;
      try {
        saved = await _service.save(
          title: draft.title,
          description: draft.description,
          visibility: draft.visibility,
          videoKey: _videoKey!,
          thumbnailKey: _thumbnailKey!,
        );
      } on ApiException catch (e) {
        if (e.code != 'already_saved') rethrow;
        // An earlier attempt saved it before its response was lost; Your
        // videos lists it.
        saved = SavedVideo(
          id: '',
          title: draft.title,
          status: VideoStatus.pending,
          visibility: draft.visibility,
        );
      }
      _browser?.setLeaveWarning(false);
      emit(UploadVideoSuccess(saved));
    } on UploadAborted {
      reset();
    } on ApiException catch (e) {
      _browser?.setLeaveWarning(false);
      final clientBug =
          stage == UploadStage.saving &&
          (e.code == 'invalid_s3_key' ||
              e.code == 'invalid_thumbnail_key' ||
              e.code == 'validation_error');
      emit(UploadVideoError(e.message, stage, retryable: !clientBug));
    }
  }

  Future<void> _uploadVideo(UploadDraft draft, UploadCancel cancel) async {
    var attempt = 0;
    var forbiddenRetried = false;
    final total = draft.video.size;
    while (true) {
      final fresh =
          _videoUrl != null &&
          _videoUrlIssuedAt != null &&
          _videoKey != null &&
          _now().difference(_videoUrlIssuedAt!) < _urlLifetime;
      if (!fresh) {
        emit(UploadVideoInProgress(UploadStage.video, totalBytes: total));
        final target = await _service.videoUrl();
        _videoUrl = target.url;
        _videoKey = target.key;
        _videoUrlIssuedAt = _now();
      }

      emit(UploadVideoInProgress(UploadStage.video, totalBytes: total));
      try {
        await _service.put(
          _videoUrl!,
          draft.video,
          'video/mp4',
          cancel: cancel,
          onProgress: (sent, t) {
            if (isClosed) return;
            emit(
              UploadVideoInProgress(
                UploadStage.video,
                sentBytes: sent,
                totalBytes: t > 0 ? t : total,
              ),
            );
          },
        );
        _videoUploaded = true;
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
        if (cancel.isCancelled) throw const UploadAborted();
      }
    }
  }

  @override
  Future<void> close() {
    _cancel?.cancel();
    _browser?.setLeaveWarning(false);
    return super.close();
  }
}
