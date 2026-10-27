import 'dart:async';

import '../models/watch_progress.dart';
import '../platform/video_player.dart';

/// Turns one watch page's [PlayerController] values into progress reports:
/// every [heartbeat] while playing; at once on pause and at the end; after a
/// seek once it settles ([seekSettle]); and whenever [reportNow] is called
/// (the page is left, or the tab hidden).
///
/// Nothing is reported until [minPlayed] has actually been played, so
/// accidental clicks don't fill the history. Played time counts only
/// position changes that match the wall clock while playing; a bigger jump
/// is a seek.
class ProgressTracker {
  ProgressTracker({
    required this.player,
    required this.videoId,
    required this.onReport,
    DateTime Function()? now,
    this.heartbeat = const Duration(seconds: 15),
    this.minPlayed = const Duration(seconds: 5),
    this.seekSettle = const Duration(seconds: 1),
  }) : _now = now ?? DateTime.now {
    _last = player.value;
    _lastAt = _now();
    player.addListener(_onValue);
  }

  final PlayerController player;
  final String videoId;
  final void Function(ProgressReport report) onReport;
  final DateTime Function() _now;
  final Duration heartbeat;
  final Duration minPlayed;
  final Duration seekSettle;

  /// How far a position change may drift from the wall clock and still
  /// count as playback rather than a seek.
  static const _tolerance = Duration(milliseconds: 1500);

  late PlayerValue _last;
  late DateTime _lastAt;
  Duration _played = Duration.zero;
  Timer? _heartbeat;
  Timer? _seek;
  bool _disposed = false;

  Duration get played => _played;

  void _onValue() {
    final v = player.value;
    final at = _now();
    final moved = v.position - _last.position;
    if (moved != Duration.zero) {
      final drift = (moved - at.difference(_lastAt)).abs();
      if (drift > _tolerance) {
        _seek?.cancel();
        _seek = Timer(seekSettle, reportNow);
      } else if (_last.playing && v.playing && moved > Duration.zero) {
        _played += moved;
      }
    }
    if (v.playing && !_last.playing) {
      _heartbeat?.cancel();
      _heartbeat = Timer.periodic(heartbeat, (_) => reportNow());
    } else if (!v.playing && _last.playing) {
      _heartbeat?.cancel();
      _heartbeat = null;
      reportNow();
    }
    if (v.ended && !_last.ended && _last.playing == v.playing) reportNow();
    _last = v;
    _lastAt = at;
  }

  /// Reports the current position, if enough has been played.
  void reportNow() {
    if (_disposed || _played < minPlayed) return;
    final v = player.value;
    final duration = v.duration > Duration.zero
        ? (v.duration.inMilliseconds / 1000).round()
        : null;
    onReport(
      ProgressReport(
        videoId: videoId,
        positionSeconds: v.position.inSeconds,
        durationSeconds: duration,
        watchedAt: _now().toUtc(),
      ),
    );
  }

  /// Stops listening; reports the position first unless [report] is false.
  void dispose({bool report = true}) {
    if (_disposed) return;
    if (report) reportNow();
    _disposed = true;
    _heartbeat?.cancel();
    _seek?.cancel();
    player.removeListener(_onValue);
  }
}
