import 'dart:async';

import '../core/api_exception.dart';
import '../platform/video_player.dart';
import 'video_service.dart';

/// Keeps one video's stream open to this browser.
///
/// The CDN only serves a video's manifests and segments to holders of the
/// signed cookies `POST /video/{id}/playback` sets, and they expire
/// ([VideoService.authorizePlayback]). [prepare] asks for them before the
/// stream opens; they are asked for again [renewBefore] they run out, so a
/// long watch never hits the end; [renew] asks at once (after the CDN
/// refused a request, e.g. when the tab slept past the expiry).
///
/// A failed request is not an error here: the stream may still open (the
/// cookies from an earlier visit can be valid), and if it can't, the player
/// says so.
class PlaybackAccess {
  PlaybackAccess(this._videos, this.videoId, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final VideoService _videos;
  final String videoId;
  final DateTime Function() _now;

  static const renewBefore = Duration(minutes: 5);

  /// Soonest a scheduled renewal runs, so a short or already-past expiry
  /// doesn't turn into a loop of requests.
  static const minRenewDelay = Duration(seconds: 30);

  Timer? _timer;
  bool _disposed = false;

  /// When the current cookies stop working, if the API said.
  DateTime? get expiresAt => _expiresAt;
  DateTime? _expiresAt;

  /// Authorizes this browser, then gives the URL to load for [source].
  Future<PlaybackSource> prepare(PlaybackSource source) async {
    await renew();
    return PlaybackSource(_videos.streamUrl(source.url), source.kind);
  }

  /// Asks for fresh cookies now. False when the API refused or failed.
  Future<bool> renew() async {
    _timer?.cancel();
    try {
      final expires = await _videos.authorizePlayback(videoId);
      if (_disposed) return false;
      _expiresAt = expires;
      _schedule(expires);
      return true;
    } on ApiException {
      return false;
    }
  }

  void _schedule(DateTime? expires) {
    _timer?.cancel();
    if (expires == null) return;
    var delay = expires.difference(_now()) - renewBefore;
    if (delay < minRenewDelay) delay = minRenewDelay;
    _timer = Timer(delay, renew);
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }
}
