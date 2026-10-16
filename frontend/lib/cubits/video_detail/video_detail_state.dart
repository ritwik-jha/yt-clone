import 'package:equatable/equatable.dart';

import '../../core/api_exception.dart';
import '../../models/progress.dart';
import '../../models/video.dart';

sealed class VideoDetailState extends Equatable {
  const VideoDetailState();
  @override
  List<Object?> get props => [];
}

class VideoDetailLoading extends VideoDetailState {
  const VideoDetailLoading(this.video);
  final Video? video;
  @override
  List<Object?> get props => [video];
}

class VideoDetailReady extends VideoDetailState {
  const VideoDetailReady(this.video);
  final Video video;
  @override
  List<Object?> get props => [video];
}

class VideoDetailProcessing extends VideoDetailState {
  const VideoDetailProcessing(this.video, this.progress);
  final Video video;
  final Progress? progress;
  @override
  List<Object?> get props => [video, progress];
}

class VideoDetailFailed extends VideoDetailState {
  const VideoDetailFailed(this.video);
  final Video video;
  @override
  List<Object?> get props => [video];
}

class VideoDetailNotFound extends VideoDetailState {
  const VideoDetailNotFound();
}

class VideoDetailDeleted extends VideoDetailState {
  const VideoDetailDeleted(this.id);
  final String id;
  @override
  List<Object?> get props => [id];
}

class VideoDetailError extends VideoDetailState {
  const VideoDetailError(this.error, this.video);
  final ApiException error;
  final Video? video;
  @override
  List<Object?> get props => [error, video];
}
