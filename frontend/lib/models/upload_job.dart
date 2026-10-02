import 'dart:io';

import 'video.dart';

/// An upload that can survive the app being killed (PLAN §7.5). Stored as
/// `<app support>/uploads/<localId>/job.json` and rewritten after each stage.
class UploadJob {
  UploadJob({
    required this.localId,
    required this.title,
    required this.description,
    required this.visibility,
    required this.videoPath,
    required this.thumbnailPath,
    this.thumbnailKey,
    this.thumbnailUploaded = false,
    this.videoKey,
    this.videoUrl,
    this.videoUrlIssuedAt,
    this.videoUploaded = false,
    this.savedVideoId,
  });

  final String localId;
  final String title;
  final String description;
  final VideoVisibility visibility;
  final String videoPath;
  final String thumbnailPath;

  String? thumbnailKey;
  bool thumbnailUploaded;
  String? videoKey;
  String? videoUrl;
  DateTime? videoUrlIssuedAt;
  bool videoUploaded;
  String? savedVideoId;

  File get video => File(videoPath);
  File get thumbnail => File(thumbnailPath);

  /// The video is in S3 (so a transcode may already be running) but the API
  /// hasn't been told: save it at once (PLAN §7.4).
  bool get needsSave =>
      videoUploaded &&
      savedVideoId == null &&
      videoKey != null &&
      thumbnailKey != null;

  Map<String, dynamic> toJson() => {
    'localId': localId,
    'title': title,
    'description': description,
    'visibility': visibility.wire,
    'videoPath': videoPath,
    'thumbnailPath': thumbnailPath,
    'thumbnailKey': thumbnailKey,
    'thumbnailUploaded': thumbnailUploaded,
    'videoKey': videoKey,
    // Presigned URLs are credentials: never persist them. A resumed job asks
    // for a fresh URL instead.
    'videoUploaded': videoUploaded,
    'savedVideoId': savedVideoId,
  };

  factory UploadJob.fromJson(Map<String, dynamic> j) => UploadJob(
    localId: j['localId'] as String,
    title: j['title'] as String,
    description: (j['description'] as String?) ?? '',
    visibility: VideoVisibility.parse(j['visibility'] as String?),
    videoPath: j['videoPath'] as String,
    thumbnailPath: j['thumbnailPath'] as String,
    thumbnailKey: j['thumbnailKey'] as String?,
    thumbnailUploaded: (j['thumbnailUploaded'] as bool?) ?? false,
    videoKey: j['videoKey'] as String?,
    videoUploaded: (j['videoUploaded'] as bool?) ?? false,
    savedVideoId: j['savedVideoId'] as String?,
  );
}
