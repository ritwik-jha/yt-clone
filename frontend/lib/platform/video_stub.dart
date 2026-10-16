import 'package:flutter/widgets.dart';

import 'video_player.dart';

/// Off the web (tests on the VM): records calls, plays nothing.
PlayerController createPlayerController() => StubPlayerController();

class StubPlayerController extends PlayerController {
  PlaybackSource? source;

  @override
  Future<void> open(PlaybackSource source, {bool autoplay = true}) async {
    this.source = source;
    value = const PlayerValue();
    if (autoplay) await play();
  }

  @override
  Future<void> play() async =>
      value = value.copyWith(playing: true, started: true, ended: false);

  @override
  void pause() => value = value.copyWith(playing: false);

  @override
  void seekTo(Duration position) => value = value.copyWith(position: position);

  @override
  void setVolume(double volume) =>
      value = value.copyWith(volume: volume, muted: volume == 0);

  @override
  void setMuted(bool muted) => value = value.copyWith(muted: muted);

  @override
  Widget buildView() => const ColoredBox(color: Color(0xFF000000));
}
