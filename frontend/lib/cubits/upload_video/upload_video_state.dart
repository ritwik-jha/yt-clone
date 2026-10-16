import 'package:equatable/equatable.dart';

import '../../models/saved_video.dart';

enum UploadStage { thumbnail, video, saving }

extension UploadStageLabel on UploadStage {
  String get label => switch (this) {
    UploadStage.thumbnail => 'Uploading thumbnail',
    UploadStage.video => 'Uploading video',
    UploadStage.saving => 'Saving',
  };
}

sealed class UploadVideoState extends Equatable {
  const UploadVideoState();
  @override
  List<Object?> get props => [];
}

class UploadVideoInitial extends UploadVideoState {
  const UploadVideoInitial();
}

class UploadVideoInProgress extends UploadVideoState {
  const UploadVideoInProgress(
    this.stage, {
    this.sentBytes = 0,
    this.totalBytes = 0,
  });
  final UploadStage stage;
  final int sentBytes;
  final int totalBytes;

  double? get fraction => stage == UploadStage.video && totalBytes > 0
      ? sentBytes / totalBytes
      : null;

  @override
  List<Object?> get props => [stage, sentBytes, totalBytes];
}

class UploadVideoSuccess extends UploadVideoState {
  const UploadVideoSuccess(this.saved);
  final SavedVideo saved;
  @override
  List<Object?> get props => [saved.id];
}

class UploadVideoError extends UploadVideoState {
  const UploadVideoError(this.message, this.stage, {this.retryable = true});
  final String message;
  final UploadStage stage;

  /// False for client bugs (400s on save) that a retry can't fix.
  final bool retryable;
  @override
  List<Object?> get props => [message, stage, retryable];
}
