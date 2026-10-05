import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/api_exception.dart';
import '../../models/page_result.dart';
import '../../models/video.dart';
import '../../services/video_service.dart';
import 'feed_state.dart';

typedef PageFetcher = Future<PageResult<Video>> Function(int page, int limit);

/// Paginated list used by Home (public feed); My Videos extends it.
class FeedCubit extends Cubit<VideoListState> {
  FeedCubit(VideoService videos, {this.limit = 10})
    : _fetch = ((page, limit) => videos.feed(page: page, limit: limit)),
      super(const VideoListState());

  FeedCubit.withFetcher(this._fetch, {this.limit = 10})
    : super(const VideoListState());

  final PageFetcher _fetch;
  final int limit;

  Future<void> load() async {
    emit(state.copyWith(status: ListStatus.loading, clearError: true));
    await _run(page: 1, replace: true);
  }

  Future<void> refresh() async {
    if (state.isBusy) return;
    emit(state.copyWith(status: ListStatus.refreshing, clearError: true));
    await _run(page: 1, replace: true);
  }

  Future<void> loadMore() async {
    if (state.isBusy || !state.hasMore || state.status == ListStatus.failure) {
      return;
    }
    emit(state.copyWith(status: ListStatus.loadingMore));
    await _run(page: state.page + 1, replace: false);
  }

  Future<void> _run({required int page, required bool replace}) async {
    try {
      final result = await _fetch(page, limit);
      // Offset pagination shifts as videos complete: de-duplicate by id.
      final seen = <String>{if (!replace) ...state.items.map((v) => v.id)};
      final merged = [
        if (!replace) ...state.items,
        for (final v in result.items)
          if (seen.add(v.id)) v,
      ];
      emit(
        state.copyWith(
          items: merged,
          page: result.page,
          total: result.total,
          status: ListStatus.success,
          clearError: true,
        ),
      );
    } on ApiException catch (e) {
      // A failed pull-to-refresh or load-more keeps what's already on screen.
      emit(
        state.copyWith(
          status: replace && state.items.isEmpty
              ? ListStatus.failure
              : ListStatus.success,
          error: e,
        ),
      );
    }
  }

  void remove(String id) {
    if (!state.items.any((v) => v.id == id)) return;
    emit(
      state.copyWith(
        items: state.items.where((v) => v.id != id).toList(),
        total: (state.total - 1).clamp(0, 1 << 30),
      ),
    );
  }

  void replace(Video video) {
    emit(
      state.copyWith(
        items: [for (final v in state.items) v.id == video.id ? video : v],
      ),
    );
  }
}
