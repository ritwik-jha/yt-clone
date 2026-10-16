import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/format.dart';
import '../core/theme.dart';
import '../platform/video_player.dart';

/// The video with the mockup's controls drawn over it: the title at the top,
/// a red progress bar, and play / volume / time / fullscreen along the
/// bottom. Controls fade out while playing and the pointer is still.
///
/// Keys (once the player has focus): Space or K play/pause, M mute,
/// F fullscreen, ←/→ 5 s, J/L 10 s, 0-9 jump to 0-90 %.
class PlayerView extends StatefulWidget {
  const PlayerView({
    super.key,
    required this.controller,
    required this.title,
    required this.posterUrl,
    required this.fullscreen,
    required this.onToggleFullscreen,
  });

  final PlayerController controller;
  final String title;
  final String posterUrl;
  final bool fullscreen;
  final VoidCallback onToggleFullscreen;

  @override
  State<PlayerView> createState() => _PlayerViewState();
}

class _PlayerViewState extends State<PlayerView> {
  late final Widget _view = widget.controller.buildView();
  final _focus = FocusNode(debugLabel: 'player');
  Timer? _hideTimer;
  bool _controlsVisible = true;
  bool _volumeHover = false;

  PlayerController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onValue);
  }

  @override
  void didUpdateWidget(PlayerView old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onValue);
      widget.controller.addListener(_onValue);
    }
  }

  @override
  void dispose() {
    _c.removeListener(_onValue);
    _hideTimer?.cancel();
    _focus.dispose();
    super.dispose();
  }

  void _onValue() {
    // Paused or ended: keep the controls up.
    if (!_c.value.playing && !_controlsVisible) _show();
  }

  void _show() {
    _hideTimer?.cancel();
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _hideTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted && _c.value.playing && !_volumeHover) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _seekBy(Duration delta) {
    final v = _c.value;
    final target = v.position + delta;
    _c.seekTo(
      target < Duration.zero
          ? Duration.zero
          : (v.duration > Duration.zero && target > v.duration
                ? v.duration
                : target),
    );
    _show();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final v = _c.value;
    if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.keyK) {
      _c.togglePlay();
    } else if (key == LogicalKeyboardKey.keyM) {
      _c.setMuted(!v.muted);
    } else if (key == LogicalKeyboardKey.keyF) {
      widget.onToggleFullscreen();
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _seekBy(const Duration(seconds: -5));
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _seekBy(const Duration(seconds: 5));
    } else if (key == LogicalKeyboardKey.keyJ) {
      _seekBy(const Duration(seconds: -10));
    } else if (key == LogicalKeyboardKey.keyL) {
      _seekBy(const Duration(seconds: 10));
    } else {
      final digit = int.tryParse(event.character ?? '');
      if (digit == null || v.duration == Duration.zero) {
        return KeyEventResult.ignored;
      }
      _c.seekTo(v.duration * (digit / 10));
    }
    _show();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focus,
    autofocus: true,
    onKeyEvent: _onKey,
    child: MouseRegion(
      onHover: (_) => _show(),
      onExit: (_) {
        if (_c.value.playing) setState(() => _controlsVisible = false);
      },
      child: ValueListenableBuilder<PlayerValue>(
        valueListenable: _c,
        builder: (context, v, _) {
          final showControls = _controlsVisible || !v.playing;
          return MouseRegion(
            cursor: showControls ? MouseCursor.defer : SystemMouseCursors.none,
            child: ColoredBox(
              color: Colors.black,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _view,
                  // Takes clicks over the <video>: toggle play, double-click
                  // for fullscreen.
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      _focus.requestFocus();
                      _c.togglePlay();
                      _show();
                    },
                    onDoubleTap: widget.onToggleFullscreen,
                    child: const SizedBox.expand(),
                  ),
                  if (!v.started && widget.posterUrl.isNotEmpty)
                    IgnorePointer(
                      child: Image.network(
                        widget.posterUrl,
                        fit: BoxFit.contain,
                        webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                  if (v.error != null)
                    _ErrorOverlay(message: v.error!)
                  else if (v.buffering)
                    const IgnorePointer(
                      child: Center(
                        child: SizedBox(
                          width: 56,
                          height: 56,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 4,
                          ),
                        ),
                      ),
                    )
                  else if (!v.playing)
                    Center(
                      child: _BigPlayButton(
                        replay: v.ended,
                        onTap: () {
                          _focus.requestFocus();
                          _c.togglePlay();
                        },
                      ),
                    ),
                  if (showControls) ...[
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 0,
                      child: IgnorePointer(child: _TopBar(title: widget.title)),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: _BottomBar(
                        value: v,
                        controller: _c,
                        fullscreen: widget.fullscreen,
                        onFullscreen: widget.onToggleFullscreen,
                        onVolumeHover: (hover) =>
                            setState(() => _volumeHover = hover),
                        volumeExpanded: _volumeHover,
                        onSeek: (to) {
                          _c.seekTo(to);
                          _show();
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    ),
  );
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xAA000000), Color(0x00000000)],
      ),
    ),
    child: Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 16, color: Colors.white),
    ),
  );
}

class _BigPlayButton extends StatelessWidget {
  const _BigPlayButton({required this.replay, required this.onTap});
  final bool replay;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: replay ? 'Replay' : 'Play',
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 68,
          height: 48,
          decoration: BoxDecoration(
            color: YtColors.red,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(
            replay ? Icons.replay : Icons.play_arrow_rounded,
            color: Colors.white,
            size: 36,
          ),
        ),
      ),
    ),
  );
}

class _ErrorOverlay extends StatelessWidget {
  const _ErrorOverlay({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.white, size: 48),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
          ],
        ),
      ),
    ),
  );
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.value,
    required this.controller,
    required this.fullscreen,
    required this.onFullscreen,
    required this.onSeek,
    required this.onVolumeHover,
    required this.volumeExpanded,
  });

  final PlayerValue value;
  final PlayerController controller;
  final bool fullscreen;
  final VoidCallback onFullscreen;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<bool> onVolumeHover;
  final bool volumeExpanded;

  @override
  Widget build(BuildContext context) {
    final v = value;
    final muted = v.muted || v.volume == 0;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 24, 12, 4),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xCC000000), Color(0x00000000)],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ProgressBar(
            position: v.position,
            buffered: v.buffered,
            duration: v.duration,
            onSeek: onSeek,
          ),
          Row(
            children: [
              _ControlButton(
                tooltip: v.playing ? 'Pause (k)' : 'Play (k)',
                icon: v.playing
                    ? Icons.pause
                    : (v.ended ? Icons.replay : Icons.play_arrow),
                onPressed: controller.togglePlay,
              ),
              MouseRegion(
                onEnter: (_) => onVolumeHover(true),
                onExit: (_) => onVolumeHover(false),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _ControlButton(
                      tooltip: muted ? 'Unmute (m)' : 'Mute (m)',
                      icon: muted
                          ? Icons.volume_off
                          : (v.volume < 0.5
                                ? Icons.volume_down
                                : Icons.volume_up),
                      onPressed: () {
                        if (muted && v.volume == 0) {
                          controller.setVolume(1);
                        } else {
                          controller.setMuted(!muted);
                        }
                      },
                    ),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 150),
                      child: SizedBox(
                        width: volumeExpanded ? 72 : 0,
                        child: volumeExpanded
                            ? SliderTheme(
                                data: const SliderThemeData(
                                  trackHeight: 3,
                                  activeTrackColor: Colors.white,
                                  inactiveTrackColor: Color(0x55FFFFFF),
                                  thumbColor: Colors.white,
                                  overlayShape: RoundSliderOverlayShape(
                                    overlayRadius: 8,
                                  ),
                                  thumbShape: RoundSliderThumbShape(
                                    enabledThumbRadius: 6,
                                  ),
                                ),
                                child: Slider(
                                  value: muted ? 0 : v.volume,
                                  onChanged: controller.setVolume,
                                  semanticFormatterCallback: (x) =>
                                      'Volume ${(x * 100).round()}%',
                                ),
                              )
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${formatDuration(v.position.inMilliseconds / 1000)} / '
                '${formatDuration(v.duration.inMilliseconds / 1000)}',
                style: const TextStyle(fontSize: 13, color: Colors.white),
              ),
              const Spacer(),
              _ControlButton(
                tooltip: fullscreen
                    ? 'Exit full screen (f)'
                    : 'Full screen (f)',
                icon: fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                onPressed: onFullscreen,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    color: Colors.white,
    iconSize: 28,
    icon: Icon(icon),
  );
}

/// The red scrubber: played red, buffered light grey, the rest dim. Thicker
/// with a handle on hover; click or drag to seek.
class ProgressBar extends StatefulWidget {
  const ProgressBar({
    super.key,
    required this.position,
    required this.buffered,
    required this.duration,
    required this.onSeek,
  });

  final Duration position;
  final Duration buffered;
  final Duration duration;
  final ValueChanged<Duration> onSeek;

  @override
  State<ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends State<ProgressBar> {
  bool _hover = false;
  double? _drag;

  double _fraction(Duration d) => widget.duration.inMilliseconds == 0
      ? 0
      : (d.inMilliseconds / widget.duration.inMilliseconds).clamp(0.0, 1.0);

  void _seekTo(double dx, double width) {
    if (widget.duration == Duration.zero || width <= 0) return;
    widget.onSeek(widget.duration * (dx / width).clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final played = _drag ?? _fraction(widget.position);
      final buffered = _fraction(widget.buffered);
      final thick = _hover || _drag != null;
      return Semantics(
        slider: true,
        label: 'Seek',
        value: formatDuration(widget.position.inMilliseconds / 1000),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => _seekTo(d.localPosition.dx, width),
            onHorizontalDragStart: (d) => setState(
              () => _drag = (d.localPosition.dx / width).clamp(0.0, 1.0),
            ),
            onHorizontalDragUpdate: (d) => setState(
              () => _drag = (d.localPosition.dx / width).clamp(0.0, 1.0),
            ),
            onHorizontalDragEnd: (_) {
              final f = _drag;
              setState(() => _drag = null);
              if (f != null) _seekTo(f * width, width);
            },
            child: SizedBox(
              height: 16,
              child: Stack(
                alignment: Alignment.centerLeft,
                clipBehavior: Clip.none,
                children: [
                  _bar(width, thick, const Color(0x33FFFFFF)),
                  _bar(width * buffered, thick, const Color(0x66FFFFFF)),
                  _bar(width * played, thick, YtColors.red),
                  if (thick)
                    Positioned(
                      left: width * played - 6.5,
                      child: Container(
                        width: 13,
                        height: 13,
                        decoration: const BoxDecoration(
                          color: YtColors.red,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _bar(double width, bool thick, Color color) => AnimatedContainer(
    duration: const Duration(milliseconds: 100),
    width: width,
    height: thick ? 5 : 3,
    color: color,
  );
}
