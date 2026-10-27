import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api_exception.dart';
import '../models/watch_progress.dart';
import '../platform/browser.dart';
import '../platform/video_player.dart';
import 'history_outbox.dart';
import 'history_service.dart';
import 'progress_tracker.dart';
import 'watch_progress_store.dart';

/// Ties watch history together for the app: the session decides whose
/// history is recorded ([signedIn], [signedOut], [beforeLogout]), the watch
/// page's [ProgressTracker] reports into the [outbox], and the [store] that
/// draws the thumbnail bars follows along. Hiding the tab reports the
/// position and posts the outbox; showing it again flushes.
///
/// If the backend predates watch history, the feature turns itself off for
/// this page load ([available]): nothing is recorded or looked up, and the
/// outbox keeps what it has.
class HistorySync {
  HistorySync({
    required Browser browser,
    required this.service,
    HistoryOutbox? outbox,
    WatchProgressStore? store,
  }) : _browser = browser,
       outbox = outbox ?? HistoryOutbox(browser: browser, service: service),
       store = store ?? WatchProgressStore(service) {
    this.outbox
      ..onResults = _adopt
      ..onUnavailable = _turnOff;
    this.store.onUnavailable = _turnOff;
    _unlisten = browser.listenForVisibility(
      onHidden: _onHidden,
      onVisible: _onVisible,
    );
  }

  final Browser _browser;
  final HistoryService service;
  final HistoryOutbox outbox;
  final WatchProgressStore store;

  /// How long [resumePoint] trusts what [store] already knows.
  static const freshFor = Duration(minutes: 1);

  late final void Function() _unlisten;
  final _available = ValueNotifier(true);
  String? _user;
  ProgressTracker? _active;

  /// False once the backend answered that it has no watch history.
  ValueListenable<bool> get available => _available;

  /// Whether this page load records history: signed in, and supported.
  bool get recording => _user != null && _available.value;

  void signedIn(String userId) {
    if (_user == userId) return;
    _user = userId;
    if (!_available.value) return;
    outbox.open(userId);
    store
      ..disable()
      ..enable();
    outbox.flush();
  }

  /// The session ended (expired, or signed out in another tab). This
  /// user's unsent reports stay for their next visit.
  void signedOut() {
    _stopTracking(report: false);
    _user = null;
    outbox.close();
    store.disable();
  }

  /// Before an explicit sign-out, while the cookies still work: send what is
  /// waiting (for up to 3 s), then forget it, so the next person on this
  /// computer never sees or sends this user's history.
  Future<void> beforeLogout() async {
    _active?.reportNow();
    if (recording) {
      try {
        await outbox.flush().timeout(const Duration(seconds: 3));
      } on TimeoutException {
        // Signing out wins; what didn't go is dropped below.
      }
    }
    _stopTracking(report: false);
    outbox.close(forget: true);
    store.disable();
    _user = null;
  }

  /// Starts recording [player] for [videoId]; null when not [recording].
  ProgressTracker? track(PlayerController player, String videoId) {
    if (!recording) return null;
    _stopTracking(report: true);
    return _active = ProgressTracker(
      player: player,
      videoId: videoId,
      onReport: report,
    );
  }

  /// The watch page is going away: report where it stopped.
  void untrack(ProgressTracker tracker) {
    tracker.dispose();
    if (identical(_active, tracker)) _active = null;
  }

  void _stopTracking({required bool report}) {
    _active?.dispose(report: report);
    _active = null;
  }

  void report(ProgressReport r) {
    if (!recording) return;
    outbox.put(r);
    store.put(WatchProgress.fromReport(r));
  }

  /// Where [videoId] should resume: the newest of what the store knows, an
  /// unsent report from this browser, and the server's entry. The server is
  /// skipped when the store's answer is fresh (the page was opened from
  /// History or a thumbnail that just looked it up).
  Future<WatchProgress?> resumePoint(String videoId) async {
    if (!recording) return null;
    var best = store.peek(videoId);
    if (outbox.pending(videoId) case final r?) {
      final local = WatchProgress.fromReport(r);
      if (local.isNewerThan(best)) best = local;
    }
    if (store.isFresh(videoId, freshFor)) return best;
    try {
      for (final p in await service.positions([videoId])) {
        store.put(p);
        if (p.isNewerThan(best)) best = p;
      }
    } on ApiException catch (e) {
      if (historyUnavailable(e)) _turnOff();
    }
    return best;
  }

  /// [videoId] was removed from history: drop its unsent report and bar.
  void forget(String videoId) {
    outbox.drop(videoId);
    store.remove(videoId);
  }

  /// History was cleared: otherwise a pending report would add an entry
  /// straight back.
  void forgetAll() {
    outbox.dropAll();
    store.clear();
  }

  /// The History page turns the feature off when the backend has none.
  void markUnavailable() => _turnOff();

  void _adopt(List<ProgressResult> results) {
    for (final r in results) {
      if (r.outcome == ProgressOutcome.stale && r.progress != null) {
        store.put(r.progress!);
      }
    }
  }

  void _turnOff() {
    if (!_available.value) return;
    _available.value = false;
    _stopTracking(report: false);
    store.disable();
  }

  void _onHidden() {
    if (!recording) return;
    _active?.reportNow();
    final body = outbox.exitBody();
    if (body != null) _browser.postOnExit(service.exitUrl, body);
  }

  void _onVisible() {
    if (recording) outbox.flush();
  }

  void dispose() {
    _unlisten();
    _stopTracking(report: false);
    outbox.dispose();
    store.dispose();
    _available.dispose();
  }
}
