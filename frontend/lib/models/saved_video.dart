import 'video.dart';

class SavedVideo {
  const SavedVideo({
    required this.id,
    required this.title,
    required this.status,
    required this.visibility,
  });

  final String id;
  final String title;
  final VideoStatus status;
  final VideoVisibility visibility;

  factory SavedVideo.fromJson(Map<String, dynamic> j) => SavedVideo(
    id: j['id'] as String,
    title: j['title'] as String,
    status: VideoStatus.parse(j['status'] as String?),
    visibility: VideoVisibility.parse(j['visibility'] as String?),
  );
}
