import 'package:equatable/equatable.dart';

import 'video.dart';

class Progress extends Equatable {
  const Progress({
    required this.videoId,
    required this.percent,
    required this.status,
  });

  final String videoId;
  final int percent;
  final VideoStatus status;

  factory Progress.fromJson(Map<String, dynamic> j) => Progress(
    videoId: j['video_id'] as String,
    percent: (j['percent'] as num).round().clamp(0, 100),
    status: VideoStatus.parse(j['status'] as String?),
  );

  @override
  List<Object?> get props => [videoId, percent, status];
}
