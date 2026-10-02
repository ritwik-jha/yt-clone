import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';

enum VideoStatus {
  pending,
  processing,
  completed,
  failed,
  unknown;

  static VideoStatus parse(String? v) => switch (v?.toUpperCase()) {
    'PENDING' => pending,
    'PROCESSING' => processing,
    'COMPLETED' => completed,
    'FAILED' => failed,
    _ => unknown,
  };

  bool get isUnfinished => this == pending || this == processing;
  bool get isTerminal => this == completed || this == failed;

  String get label => switch (this) {
    pending => 'Pending',
    processing => 'Processing',
    completed => 'Ready',
    failed => 'Failed',
    unknown => 'Unknown',
  };
}

// Not "Visibility": that clashes with the Flutter widget.
enum VideoVisibility {
  public,
  private,
  unlisted,
  unknown;

  static VideoVisibility parse(String? v) => switch (v?.toUpperCase()) {
    'PUBLIC' => public,
    'PRIVATE' => private,
    'UNLISTED' => unlisted,
    _ => unknown,
  };

  String get wire => name.toUpperCase();

  String get label => switch (this) {
    public => 'Public',
    private => 'Private',
    unlisted => 'Unlisted',
    unknown => 'Unknown',
  };
}

class Creator extends Equatable {
  const Creator({required this.id, required this.name, this.createdAt});

  final String id;
  final String name;
  final DateTime? createdAt;

  factory Creator.fromJson(Map<String, dynamic> j) => Creator(
    id: j['id'] as String,
    name: j['name'] as String,
    createdAt: j['created_at'] == null
        ? null
        : DateTime.parse(j['created_at'] as String),
  );

  @override
  List<Object?> get props => [id, name, createdAt];
}

/// Covers both `FeedItem` and `VideoDetail` (plan §5.8). Feed items carry no
/// `visibility` or `status`, which means PUBLIC and COMPLETED.
class Video extends Equatable {
  const Video({
    required this.id,
    required this.title,
    required this.thumbnailUrl,
    required this.viewsCount,
    required this.creator,
    required this.createdAt,
    this.description,
    this.manifestUrl,
    this.hlsUrl,
    this.durationSeconds,
    this.visibility,
    this.status,
  });

  final String id;
  final String title;
  final String? description;
  final String thumbnailUrl;
  final String? manifestUrl;
  final String? hlsUrl;
  final int viewsCount;
  final double? durationSeconds;
  final Creator creator;
  final DateTime createdAt;
  final VideoVisibility? visibility;
  final VideoStatus? status;

  VideoStatus get effectiveStatus => status ?? VideoStatus.completed;
  VideoVisibility get effectiveVisibility =>
      visibility ?? VideoVisibility.public;

  /// DASH on Android, HLS on iOS (plan D10).
  String? playbackUrlFor(TargetPlatform platform) =>
      platform == TargetPlatform.iOS ? hlsUrl : manifestUrl;

  String? get playbackUrl => playbackUrlFor(defaultTargetPlatform);
  bool get isPlayable => playbackUrl != null;

  factory Video.fromJson(Map<String, dynamic> j) => Video(
    id: j['id'] as String,
    title: j['title'] as String,
    description: j['description'] as String?,
    thumbnailUrl: (j['thumbnail_url'] as String?) ?? '',
    manifestUrl: j['manifest_url'] as String?,
    hlsUrl: j['hls_url'] as String?,
    viewsCount: (j['views_count'] as num?)?.toInt() ?? 0,
    durationSeconds: (j['duration_seconds'] as num?)?.toDouble(),
    creator: Creator.fromJson(j['creator'] as Map<String, dynamic>),
    createdAt: DateTime.parse(j['created_at'] as String),
    visibility: j['visibility'] == null
        ? null
        : VideoVisibility.parse(j['visibility'] as String?),
    status: j['status'] == null
        ? null
        : VideoStatus.parse(j['status'] as String?),
  );

  Video copyWith({
    String? title,
    String? description,
    bool clearDescription = false,
    int? viewsCount,
    VideoVisibility? visibility,
    VideoStatus? status,
  }) => Video(
    id: id,
    title: title ?? this.title,
    description: clearDescription ? null : (description ?? this.description),
    thumbnailUrl: thumbnailUrl,
    manifestUrl: manifestUrl,
    hlsUrl: hlsUrl,
    viewsCount: viewsCount ?? this.viewsCount,
    durationSeconds: durationSeconds,
    creator: creator,
    createdAt: createdAt,
    visibility: visibility ?? this.visibility,
    status: status ?? this.status,
  );

  @override
  List<Object?> get props => [
    id,
    title,
    description,
    thumbnailUrl,
    manifestUrl,
    hlsUrl,
    viewsCount,
    durationSeconds,
    creator,
    createdAt,
    visibility,
    status,
  ];
}

/// PATCH body. Serialises only fields that changed (plan §4.2); an empty
/// description clears it.
class VideoUpdate {
  const VideoUpdate({this.title, this.description, this.visibility});

  final String? title;
  final String? description;
  final VideoVisibility? visibility;

  bool get isEmpty =>
      title == null && description == null && visibility == null;

  Map<String, dynamic> toJson() => {
    if (title != null) 'title': title,
    if (description != null) 'description': description,
    if (visibility != null) 'visibility': visibility!.wire,
  };
}

/// What the player page hands back to the page that opened it (plan §5.6).
sealed class VideoChange {
  const VideoChange();
}

class VideoUpdated extends VideoChange {
  const VideoUpdated(this.video);
  final Video video;
}

class VideoDeleted extends VideoChange {
  const VideoDeleted(this.id);
  final String id;
}
