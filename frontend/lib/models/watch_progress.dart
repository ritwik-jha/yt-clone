import 'dart:math' as math;

import 'package:equatable/equatable.dart';

import 'video.dart';

/// How far the signed-in user got in one video (`WatchProgress` in the API).
class WatchProgress extends Equatable {
  const WatchProgress({
    required this.videoId,
    required this.positionSeconds,
    required this.completed,
    required this.lastWatchedAt,
    this.durationSeconds,
  });

  final String videoId;
  final int positionSeconds;
  final int? durationSeconds;
  final bool completed;

  /// When this position was observed, in UTC. Newer wins.
  final DateTime lastWatchedAt;

  factory WatchProgress.fromJson(Map<String, dynamic> j) => WatchProgress(
    videoId: j['video_id'] as String,
    positionSeconds: (j['position_seconds'] as num).toInt(),
    durationSeconds: (j['duration_seconds'] as num?)?.toInt(),
    completed: j['completed'] as bool,
    lastWatchedAt: DateTime.parse(j['last_watched_at'] as String).toUtc(),
  );

  /// What a report from this browser amounts to, before the server answers.
  /// Uses the server's completion rule (95 %, or 10 s or less left).
  factory WatchProgress.fromReport(ProgressReport r) {
    final d = r.durationSeconds;
    final pos = d == null ? r.positionSeconds : math.min(r.positionSeconds, d);
    return WatchProgress(
      videoId: r.videoId,
      positionSeconds: pos,
      durationSeconds: d,
      completed: d != null && (pos >= 0.95 * d || d - pos <= 10),
      lastWatchedAt: r.watchedAt,
    );
  }

  /// 0–1 for the bar on a thumbnail; a finished video shows a full bar.
  double get fraction {
    if (completed) return 1;
    final d = durationSeconds;
    if (d == null || d <= 0) return 0;
    return (positionSeconds / d).clamp(0.0, 1.0);
  }

  /// Where to start playing, or null to start from the beginning: null when
  /// finished or under 5 s in; otherwise 2 s before the position, so the
  /// viewer sees a moment of context again.
  Duration? get resumeAt {
    if (completed || positionSeconds < 5) return null;
    return Duration(seconds: positionSeconds - 2);
  }

  bool isNewerThan(WatchProgress? other) =>
      other == null || lastWatchedAt.isAfter(other.lastWatchedAt);

  @override
  List<Object?> get props => [
    videoId,
    positionSeconds,
    durationSeconds,
    completed,
    lastWatchedAt,
  ];
}

/// One row of the History page.
class HistoryEntry extends Equatable {
  const HistoryEntry({required this.video, required this.progress});

  final Video video;
  final WatchProgress progress;

  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry(
    video: Video.fromJson(j['video'] as Map<String, dynamic>),
    progress: WatchProgress.fromJson(j['progress'] as Map<String, dynamic>),
  );

  @override
  List<Object?> get props => [video, progress];
}

/// A page of `GET /history`. [nextCursor] is null at the end.
class HistoryPage {
  const HistoryPage({required this.items, this.nextCursor});

  final List<HistoryEntry> items;
  final String? nextCursor;

  factory HistoryPage.fromJson(Map<String, dynamic> j) => HistoryPage(
    items: [
      for (final e in j['items'] as List<dynamic>)
        HistoryEntry.fromJson(e as Map<String, dynamic>),
    ],
    nextCursor: j['next_cursor'] as String?,
  );
}

/// A position this browser observed, waiting to be sent (an entry of
/// `POST /history/progress`). Also the value kept in the outbox.
class ProgressReport extends Equatable {
  const ProgressReport({
    required this.videoId,
    required this.positionSeconds,
    required this.watchedAt,
    this.durationSeconds,
  });

  final String videoId;
  final int positionSeconds;
  final int? durationSeconds;

  /// UTC. The server keeps the report with the latest one.
  final DateTime watchedAt;

  Map<String, dynamic> toJson() => {
    'video_id': videoId,
    'position_seconds': positionSeconds,
    if (durationSeconds != null) 'duration_seconds': durationSeconds,
    'watched_at': watchedAt.toUtc().toIso8601String(),
  };

  factory ProgressReport.fromJson(Map<String, dynamic> j) => ProgressReport(
    videoId: j['video_id'] as String,
    positionSeconds: (j['position_seconds'] as num).toInt(),
    durationSeconds: (j['duration_seconds'] as num?)?.toInt(),
    watchedAt: DateTime.parse(j['watched_at'] as String).toUtc(),
  );

  /// Re-sends a stored entry as it was (History's undo).
  factory ProgressReport.fromProgress(WatchProgress p) => ProgressReport(
    videoId: p.videoId,
    positionSeconds: p.positionSeconds,
    durationSeconds: p.durationSeconds,
    watchedAt: p.lastWatchedAt,
  );

  @override
  List<Object?> get props => [
    videoId,
    positionSeconds,
    durationSeconds,
    watchedAt,
  ];
}

enum ProgressOutcome {
  /// Stored.
  saved,

  /// Ignored: the server has a newer observation, in [ProgressResult.progress].
  stale,

  /// No such video, or the user can't watch it.
  notFound,

  /// Observed more than 30 days ago.
  expired;

  static ProgressOutcome parse(String v) => switch (v) {
    'saved' => saved,
    'stale' => stale,
    'not_found' => notFound,
    'expired' => expired,
    _ => throw FormatException('unknown history result: $v'),
  };
}

/// The server's answer for one entry of a batch.
class ProgressResult extends Equatable {
  const ProgressResult({
    required this.videoId,
    required this.outcome,
    this.progress,
  });

  final String videoId;
  final ProgressOutcome outcome;
  final WatchProgress? progress;

  factory ProgressResult.fromJson(Map<String, dynamic> j) => ProgressResult(
    videoId: j['video_id'] as String,
    outcome: ProgressOutcome.parse(j['result'] as String),
    progress: j['progress'] == null
        ? null
        : WatchProgress.fromJson(j['progress'] as Map<String, dynamic>),
  );

  @override
  List<Object?> get props => [videoId, outcome, progress];
}
