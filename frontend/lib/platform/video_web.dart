import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import 'video_player.dart';

PlayerController createPlayerController() => _WebPlayerController();

// Served from web/vendor (see its README), resolved against <base href>.
const _hlsScript = 'vendor/hls.js-1.5.20/hls.min.js';
const _dashScript = 'vendor/dashjs-4.7.4/dash.all.min.js';

/// A `<video>` element shown through [HtmlElementView]. Chrome and Firefox
/// play HLS through hls.js (Media Source Extensions); Safari plays it
/// natively. DASH-only videos go through dash.js.
class _WebPlayerController extends PlayerController {
  _WebPlayerController() : _viewType = 'ytp-video-${_nextId++}' {
    _el.style
      ..width = '100%'
      ..height = '100%'
      ..backgroundColor = 'black'
      ..objectFit = 'contain'
      // Flutter draws the controls and takes every click.
      ..pointerEvents = 'none';
    _el
      ..preload = 'auto'
      ..playsInline = true;
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int _) => _el);
    for (final type in const [
      'timeupdate',
      'durationchange',
      'loadedmetadata',
      'progress',
      'play',
      'pause',
      'playing',
      'waiting',
      'canplay',
      'seeked',
      'ended',
      'volumechange',
    ]) {
      _listen(type, (_) => _sync());
    }
    _listen('error', (_) => _fail(_el.error?.message));
  }

  static int _nextId = 0;

  final web.HTMLVideoElement _el = web.HTMLVideoElement();
  final String _viewType;
  final _listeners = <(String, JSFunction)>[];
  JSObject? _hls;
  JSObject? _dash;
  // A resume seek waiting for this source's metadata.
  JSFunction? _pendingSeek;
  bool _recoveredMedia = false;
  bool _disposed = false;

  void _listen(String type, void Function(web.Event) handler) {
    final fn = handler.toJS;
    _listeners.add((type, fn));
    _el.addEventListener(type, fn);
  }

  Duration _seconds(num s) => s.isFinite && s >= 0
      ? Duration(milliseconds: (s * 1000).round())
      : Duration.zero;

  Duration _bufferedEnd() {
    final ranges = _el.buffered;
    final t = _el.currentTime;
    for (var i = 0; i < ranges.length; i++) {
      if (ranges.start(i) <= t + 0.5 && t <= ranges.end(i)) {
        return _seconds(ranges.end(i));
      }
    }
    return Duration.zero;
  }

  void _sync() {
    if (_disposed) return;
    final playing = !_el.paused && !_el.ended;
    value = value.copyWith(
      position: _seconds(_el.currentTime),
      duration: _seconds(_el.duration),
      buffered: _bufferedEnd(),
      playing: playing,
      // HAVE_FUTURE_DATA (3) or better means it can keep going.
      buffering: playing && _el.readyState < 3,
      ended: _el.ended,
      volume: _el.volume.toDouble(),
      muted: _el.muted,
      started: value.started || playing,
    );
  }

  void _fail(String? message) {
    if (_disposed) return;
    value = value.copyWith(
      playing: false,
      buffering: false,
      error: (message == null || message.isEmpty)
          ? "This video can't be played right now."
          : "This video can't be played right now. ($message)",
    );
  }

  void _teardown() {
    _cancelPendingSeek();
    _hls?.callMethod<JSAny?>('destroy'.toJS);
    _hls = null;
    _dash?.callMethod<JSAny?>('reset'.toJS);
    _dash = null;
    _recoveredMedia = false;
    _el.removeAttribute('src');
    _el.load();
  }

  @override
  Future<void> open(
    PlaybackSource source, {
    bool autoplay = true,
    Duration? startAt,
  }) async {
    _teardown();
    value = PlayerValue(volume: value.volume, muted: value.muted);
    final start = startAt == null || startAt <= Duration.zero
        ? null
        : startAt.inMilliseconds / 1000;
    try {
      switch (source.kind) {
        case StreamKind.hls:
          await _openHls(source.url, start);
        case StreamKind.dash:
          if (start != null) _seekOnMetadata(start);
          await _openDash(source.url);
      }
    } on Object catch (e) {
      _fail(e is _PlayerError ? e.message : null);
      return;
    }
    if (autoplay && !_disposed) await play();
  }

  /// Seeks to [seconds] once the element knows the duration: native HLS
  /// (Safari) and dash.js take no start position of their own.
  void _seekOnMetadata(double seconds) {
    final once = ((web.Event _) {
      _cancelPendingSeek();
      final d = _el.duration;
      _el.currentTime = d.isFinite ? seconds.clamp(0, d) : seconds;
    }).toJS;
    _pendingSeek = once;
    _el.addEventListener('loadedmetadata', once);
  }

  void _cancelPendingSeek() {
    if (_pendingSeek case final fn?) {
      _el.removeEventListener('loadedmetadata', fn);
    }
    _pendingSeek = null;
  }

  Future<void> _openHls(String url, double? start) async {
    if (_el.canPlayType('application/vnd.apple.mpegurl').isNotEmpty) {
      if (start != null) _seekOnMetadata(start);
      _el.src = url;
      return;
    }
    await _loadScript(_hlsScript, 'Hls');
    final ctor = globalContext['Hls']! as JSFunction;
    if (!(ctor as JSObject).callMethod<JSBoolean>('isSupported'.toJS).toDart) {
      throw const _PlayerError('this browser has no Media Source support');
    }
    // startPosition: the first segment fetched is the one to resume in.
    final hls = start == null
        ? ctor.callAsConstructor<JSObject>()
        : ctor.callAsConstructor<JSObject>({'startPosition': start}.jsify());
    hls.callMethod<JSAny?>(
      'on'.toJS,
      'hlsError'.toJS,
      ((JSAny? _, JSObject data) {
        if (data['fatal']?.dartify() != true) return;
        final type = (data['type'] as JSString?)?.toDart;
        if (type == 'mediaError' && !_recoveredMedia) {
          _recoveredMedia = true;
          hls.callMethod<JSAny?>('recoverMediaError'.toJS);
        } else {
          _fail((data['details'] as JSString?)?.toDart);
        }
      }).toJS,
    );
    hls.callMethod<JSAny?>('loadSource'.toJS, url.toJS);
    hls.callMethod<JSAny?>('attachMedia'.toJS, _el);
    _hls = hls;
  }

  Future<void> _openDash(String url) async {
    await _loadScript(_dashScript, 'dashjs');
    final dashjs = globalContext['dashjs']! as JSObject;
    final player = dashjs
        .callMethod<JSObject>('MediaPlayer'.toJS)
        .callMethod<JSObject>('create'.toJS);
    player.callMethod<JSAny?>(
      'on'.toJS,
      'error'.toJS,
      ((JSAny? _) => _fail('DASH stream error')).toJS,
    );
    player.callMethod<JSAny?>('initialize'.toJS, _el, url.toJS, false.toJS);
    _dash = player;
  }

  @override
  Future<void> play() async {
    try {
      await _el.play().toDart;
    } on Object {
      // Autoplay refused (no user gesture yet) or the load was replaced.
      // The big play button stays up.
      _sync();
    }
  }

  @override
  void pause() => _el.pause();

  @override
  void seekTo(Duration position) {
    final s = position.inMilliseconds / 1000;
    final d = _el.duration;
    _el.currentTime = d.isFinite ? s.clamp(0, d) : s;
    _sync();
  }

  @override
  void setVolume(double volume) {
    _el.volume = volume.clamp(0, 1);
    _el.muted = volume == 0;
  }

  @override
  void setMuted(bool muted) => _el.muted = muted;

  @override
  Widget buildView() => HtmlElementView(viewType: _viewType);

  @override
  void dispose() {
    _disposed = true;
    _teardown();
    for (final (type, fn) in _listeners) {
      _el.removeEventListener(type, fn);
    }
    super.dispose();
  }
}

class _PlayerError implements Exception {
  const _PlayerError(this.message);
  final String message;
}

final _scripts = <String, Future<void>>{};

/// Adds a `<script>` once and waits for it to define [global].
Future<void> _loadScript(String src, String global) {
  if (globalContext.has(global)) return Future.value();
  return _scripts.putIfAbsent(src, () {
    final done = Completer<void>();
    // UMD bundles register with an AMD loader instead of setting their
    // global when one is present (debug builds can have one).
    final define = globalContext['define'];
    globalContext['define'] = null;
    void restore() => globalContext['define'] = define;
    final script = web.HTMLScriptElement()
      ..src = src
      ..async = true;
    script.addEventListener(
      'load',
      ((web.Event _) {
        restore();
        if (globalContext.has(global)) {
          done.complete();
        } else {
          done.completeError(const _PlayerError('the player failed to load'));
        }
      }).toJS,
    );
    script.addEventListener(
      'error',
      ((web.Event _) {
        restore();
        _scripts.remove(src);
        done.completeError(const _PlayerError('the player failed to load'));
      }).toJS,
    );
    web.document.head!.append(script);
    return done.future;
  });
}
