import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/api_exception.dart';
import '../../models/video.dart';
import '../../services/video_service.dart';
import 'video_detail_state.dart';

class VideoDetailCubit extends Cubit<VideoDetailState> {
  VideoDetailCubit(
    this._videos, {
    Video? initial,
    this.pollInterval = const Duration(seconds: 5),
  }) : _initial = initial,
       super(VideoDetailLoading(initial));

  final VideoService _videos;
  final Video? _initial;
  final Duration pollInterval;
  Timer? _timer;
  bool _viewRecorded = false;

  /// The latest known version of the video, for the page to hand back.
  Video? get video => switch (state) {
    VideoDetailLoading(:final video) => video,
    VideoDetailReady(:final video) => video,
    VideoDetailProcessing(:final video) => video,
    VideoDetailFailed(:final video) => video,
    VideoDetailError(:final video) => video,
    _ => null,
  };

  Future<void> load(String id) async {
    _timer?.cancel();
    emit(VideoDetailLoading(video ?? _initial));
    try {
      _apply(await _videos.detail(id));
    } on ApiException catch (e) {
      if (e.code == 'video_not_found') {
        emit(const VideoDetailNotFound());
      } else {
        emit(VideoDetailError(e, video ?? _initial));
      }
    }
  }

  void _apply(Video v) {
    switch (v.effectiveStatus) {
      case VideoStatus.completed:
        _timer?.cancel();
        emit(VideoDetailReady(v));
      case VideoStatus.failed:
        _timer?.cancel();
        emit(VideoDetailFailed(v));
      case VideoStatus.pending || VideoStatus.processing || VideoStatus.unknown:
        emit(VideoDetailProcessing(v, null));
        _timer?.cancel();
        _timer = Timer.periodic(pollInterval, (_) => _poll(v.id));
    }
  }

  Future<void> _poll(String id) async {
    try {
      final p = await _videos.progress(id);
      if (isClosed) return;
      if (p.status.isTerminal) {
        _timer?.cancel();
        _apply(await _videos.detail(id));
      } else if (state is VideoDetailProcessing) {
        emit(
          VideoDetailProcessing(
            (state as VideoDetailProcessing).video.copyWith(status: p.status),
            p,
          ),
        );
      }
    } on ApiException catch (e) {
      if (e.code == 'video_not_found') {
        _timer?.cancel();
        if (!isClosed) emit(const VideoDetailNotFound());
      }
    }
  }

  /// One `POST /view` per player page (plan D18). Errors are swallowed.
  Future<void> recordView() async {
    if (_viewRecorded) return;
    final current = state;
    if (current is! VideoDetailReady) return;
    _viewRecorded = true;
    emit(
      VideoDetailReady(
        current.video.copyWith(viewsCount: current.video.viewsCount + 1),
      ),
    );
    try {
      await _videos.recordView(current.video.id);
    } on ApiException {
      // A lost view isn't worth a retry.
    }
  }

  Future<void> update(VideoUpdate changes) async {
    final current = video;
    if (current == null || changes.isEmpty) return;
    try {
      final updated = await _videos.update(current.id, changes);
      _apply(updated);
    } on ApiException catch (e) {
      if (e.code == 'video_not_found') {
        emit(const VideoDetailNotFound());
      }
      rethrow;
    }
  }

  Future<void> delete() async {
    final current = video;
    if (current == null) return;
    try {
      await _videos.delete(current.id);
    } on ApiException catch (e) {
      if (e.code != 'video_not_found') rethrow;
    }
    emit(VideoDetailDeleted(current.id));
  }

  @override
  Future<void> close() {
    _timer?.cancel();
    return super.close();
  }
}
