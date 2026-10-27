import 'package:equatable/equatable.dart';
import 'package:flutter/widgets.dart';

import 'video_stub.dart' if (dart.library.js_interop) 'video_web.dart' as impl;

enum StreamKind { hls, dash }

/// What the player loads: the HLS master playlist, or the DASH manifest for
/// videos transcoded before the pipeline wrote HLS.
class PlaybackSource extends Equatable {
  const PlaybackSource(this.url, this.kind);
  final String url;
  final StreamKind kind;

  @override
  List<Object?> get props => [url, kind];
}

class PlayerValue extends Equatable {
  const PlayerValue({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.buffered = Duration.zero,
    this.playing = false,
    this.buffering = false,
    this.ended = false,
    this.volume = 1,
    this.muted = false,
    this.started = false,
    this.error,
  });

  final Duration position;
  final Duration duration;

  /// End of the buffered range around [position].
  final Duration buffered;
  final bool playing;
  final bool buffering;
  final bool ended;
  final double volume;
  final bool muted;

  /// Playback has begun at least once (hides the poster).
  final bool started;
  final String? error;

  PlayerValue copyWith({
    Duration? position,
    Duration? duration,
    Duration? buffered,
    bool? playing,
    bool? buffering,
    bool? ended,
    double? volume,
    bool? muted,
    bool? started,
    String? error,
    bool clearError = false,
  }) => PlayerValue(
    position: position ?? this.position,
    duration: duration ?? this.duration,
    buffered: buffered ?? this.buffered,
    playing: playing ?? this.playing,
    buffering: buffering ?? this.buffering,
    ended: ended ?? this.ended,
    volume: volume ?? this.volume,
    muted: muted ?? this.muted,
    started: started ?? this.started,
    error: clearError ? null : (error ?? this.error),
  );

  @override
  List<Object?> get props => [
    position,
    duration,
    buffered,
    playing,
    buffering,
    ended,
    volume,
    muted,
    started,
    error,
  ];
}

/// One `<video>` element and the streaming library attached to it. The app
/// draws the controls; [buildView] is only the picture.
abstract class PlayerController extends ValueNotifier<PlayerValue> {
  PlayerController() : super(const PlayerValue());

  /// Loads [source], replacing whatever was playing. [startAt] starts it
  /// part-way in (resuming where the viewer stopped).
  Future<void> open(
    PlaybackSource source, {
    bool autoplay = true,
    Duration? startAt,
  });

  Future<void> play();
  void pause();
  void seekTo(Duration position);
  void setVolume(double volume);
  void setMuted(bool muted);

  Widget buildView();

  void togglePlay() {
    if (value.playing) {
      pause();
    } else {
      if (value.ended) seekTo(Duration.zero);
      play();
    }
  }
}

PlayerController createPlayerController() => impl.createPlayerController();
