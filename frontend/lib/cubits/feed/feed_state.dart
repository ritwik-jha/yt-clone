import 'package:equatable/equatable.dart';

import '../../core/api_exception.dart';
import '../../models/progress.dart';
import '../../models/video.dart';

enum ListStatus { initial, loading, loadingMore, refreshing, success, failure }

/// Shared by the feed and My Videos (plan §5.6).
class VideoListState extends Equatable {
  const VideoListState({
    this.items = const [],
    this.page = 0,
    this.total = 0,
    this.status = ListStatus.initial,
    this.error,
    this.progress = const {},
  });

  final List<Video> items;
  final int page;
  final int total;
  final ListStatus status;
  final ApiException? error;
  final Map<String, Progress> progress;

  bool get hasMore => items.length < total;
  bool get isBusy =>
      status == ListStatus.loading ||
      status == ListStatus.loadingMore ||
      status == ListStatus.refreshing;

  VideoListState copyWith({
    List<Video>? items,
    int? page,
    int? total,
    ListStatus? status,
    ApiException? error,
    bool clearError = false,
    Map<String, Progress>? progress,
  }) => VideoListState(
    items: items ?? this.items,
    page: page ?? this.page,
    total: total ?? this.total,
    status: status ?? this.status,
    error: clearError ? null : (error ?? this.error),
    progress: progress ?? this.progress,
  );

  @override
  List<Object?> get props => [items, page, total, status, error, progress];
}
