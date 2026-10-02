import 'dart:async';

import '../../core/api_exception.dart';
import '../../models/video.dart';
import '../../services/video_service.dart';
import '../feed/feed_cubit.dart';

/// The owner's videos, with progress polling for unfinished ones (plan §6.7).
class MyVideosCubit extends FeedCubit {
  MyVideosCubit(this._videos, {this.pollInterval = const Duration(seconds: 5)})
    : super.withFetcher(
        (page, limit) => _videos.mine(page: page, limit: limit),
      );

  final VideoService _videos;
  final Duration pollInterval;
  Timer? _timer;
  bool _paused = false;
  bool _polling = false;

  static const _maxPolled = 10;

  Iterable<Video> get _unfinished =>
      state.items.where((v) => v.effectiveStatus.isUnfinished);

  void startPolling() {
    _timer?.cancel();
    _timer = Timer.periodic(pollInterval, (_) => poll());
  }

  void stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  /// Paused while the app is in the background.
  void setPaused(bool paused) => _paused = paused;

  Future<void> poll() async {
    if (_paused || _polling || isClosed) return;
    final targets = _unfinished.take(_maxPolled).toList();
    if (targets.isEmpty) return;
    _polling = true;
    try {
      for (final video in targets) {
        if (isClosed) return;
        try {
          final p = await _videos.progress(video.id);
          if (isClosed) return;
          if (p.status.isTerminal) {
            final fresh = await _videos.detail(video.id);
            if (isClosed) return;
            replace(fresh);
          } else {
            replace(video.copyWith(status: p.status));
          }
          emit(state.copyWith(progress: {...state.progress, video.id: p}));
        } on ApiException catch (e) {
          if (e.code == 'video_not_found') remove(video.id);
        }
      }
    } finally {
      _polling = false;
    }
  }

  void applyChange(VideoChange change) {
    switch (change) {
      case VideoUpdated(:final video):
        replace(video);
      case VideoDeleted(:final id):
        remove(id);
    }
  }

  Future<void> updateVideo(String id, VideoUpdate changes) async {
    final updated = await _videos.update(id, changes);
    replace(updated);
  }

  Future<void> deleteVideo(String id) async {
    try {
      await _videos.delete(id);
    } on ApiException catch (e) {
      if (e.code != 'video_not_found') rethrow;
    }
    remove(id);
  }

  @override
  Future<void> close() {
    stopPolling();
    return super.close();
  }
}
