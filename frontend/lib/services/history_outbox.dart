import 'dart:async';
import 'dart:convert';

import '../core/api_exception.dart';
import '../models/watch_progress.dart';
import '../platform/browser.dart';
import 'history_service.dart';

/// Progress reports waiting to reach the server, for the signed-in user.
///
/// Every report is written to `localStorage` before any network call, one
/// key per (user, video): `ytp.history.<userId>.<videoId>`. Writing storage
/// is synchronous, so a report survives the tab closing mid-request, and one
/// key per video lets several tabs write without overwriting each other. A
/// key only ever moves forward: a write is dropped if the stored report is
/// as new or newer. The same reports are kept in memory, so the page still
/// works when storage is blocked.
///
/// [flush] sends up to [HistoryService.maxBatch] at a time and removes a key
/// only if it still holds the report that was sent, so a newer report
/// written during the request survives. Network errors and 5xx keep
/// everything for the next flush.
class HistoryOutbox {
  HistoryOutbox({
    required this._browser,
    required this._service,
    DateTime Function()? now,
    this.flushDelay = const Duration(seconds: 2),
    this.retryEvery = const Duration(seconds: 60),
  }) : _now = now ?? DateTime.now;

  static const prefix = 'ytp.history.';

  /// Older reports are dropped unsent: the server would answer `expired`.
  static const maxAge = Duration(days: 30);

  final Browser _browser;
  final HistoryService _service;
  final DateTime Function() _now;
  final Duration flushDelay;
  final Duration retryEvery;

  /// Results of each flushed batch (for adopting `stale` answers).
  void Function(List<ProgressResult> results)? onResults;

  /// The backend has no watch history (see [historyUnavailable]).
  void Function()? onUnavailable;

  String? _user;
  final _memory = <String, ProgressReport>{};
  Timer? _debounce;
  Timer? _retry;
  Future<void>? _flushing;
  bool _again = false;

  String? get userId => _user;

  String _userPrefix(String user) => '$prefix$user.';
  String _key(String user, String videoId) => '${_userPrefix(user)}$videoId';

  /// Starts collecting for [userId], picking up what earlier visits left.
  void open(String userId) {
    if (_user == userId) return;
    close();
    _user = userId;
    for (final key in _browser.localKeys(_userPrefix(userId))) {
      final r = _parse(key);
      if (r != null) _memory[r.videoId] = r;
    }
  }

  /// Stops collecting. The stored reports stay for this user's next visit
  /// unless [forget] (an explicit sign-out: the next person on this computer
  /// must not send or see them).
  void close({bool forget = false}) {
    final user = _user;
    if (user != null && forget) {
      for (final key in _browser.localKeys(_userPrefix(user))) {
        _browser.removeLocal(key);
      }
    }
    _user = null;
    _memory.clear();
    _debounce?.cancel();
    _retry?.cancel();
  }

  bool get isEmpty => _all().isEmpty;

  /// Keeps [report] unless a report as new or newer is already waiting.
  void put(ProgressReport report) {
    final user = _user;
    if (user == null) return;
    final current = pending(report.videoId);
    if (current != null && !report.watchedAt.isAfter(current.watchedAt)) {
      return;
    }
    _browser.writeLocal(
      _key(user, report.videoId),
      jsonEncode(report.toJson()),
    );
    _memory[report.videoId] = report;
    _debounce?.cancel();
    _debounce = Timer(flushDelay, flush);
  }

  /// The newest unsent report for [videoId], from any tab.
  ProgressReport? pending(String videoId) {
    final user = _user;
    if (user == null) return null;
    final stored = _parse(_key(user, videoId));
    final mine = _memory[videoId];
    if (stored == null) return mine;
    if (mine == null || stored.watchedAt.isAfter(mine.watchedAt)) {
      return stored;
    }
    return mine;
  }

  /// Forgets the unsent report for [videoId] (removed from history).
  void drop(String videoId) {
    final user = _user;
    if (user == null) return;
    _browser.removeLocal(_key(user, videoId));
    _memory.remove(videoId);
  }

  /// Forgets every unsent report of this user (history cleared).
  void dropAll() {
    final user = _user;
    if (user == null) return;
    for (final key in _browser.localKeys(_userPrefix(user))) {
      _browser.removeLocal(key);
    }
    _memory.clear();
  }

  /// The body for a keepalive POST from a closing tab, or null when there is
  /// nothing to send. The keys stay: the tab can't read the answer, so the
  /// next visit sends them again, and an equal `watched_at` overwrites
  /// itself on the server.
  String? exitBody() {
    final reports = _all();
    if (reports.isEmpty) return null;
    return HistoryService.exitBody(
      reports.take(HistoryService.maxBatch).toList(),
    );
  }

  /// Sends everything waiting. A call while a flush is running makes that
  /// run go round once more (for reports written after it started) and
  /// shares its future.
  Future<void> flush() {
    if (_flushing case final running?) {
      _again = true;
      return running;
    }
    return _flushing = _flushUntilDone().whenComplete(() {
      _flushing = null;
    });
  }

  Future<void> _flushUntilDone() async {
    do {
      _again = false;
      await _flush();
    } while (_again && _user != null);
  }

  Future<void> _flush() async {
    _debounce?.cancel();
    final user = _user;
    if (user == null) return;
    while (_user == user) {
      final batch = _all().take(HistoryService.maxBatch).toList();
      if (batch.isEmpty) break;
      final List<ProgressResult> results;
      try {
        results = await _service.record(batch);
      } on ApiException catch (e) {
        if (historyUnavailable(e)) onUnavailable?.call();
        break;
      }
      final sent = {for (final r in batch) r.videoId: r};
      var removed = 0;
      for (final result in results) {
        final report = sent[result.videoId];
        if (report == null) continue;
        // A newer report written while the request was out stays.
        if (_parse(_key(user, result.videoId)) case final stored?
            when stored != report) {
          continue;
        }
        _browser.removeLocal(_key(user, result.videoId));
        if (_user == user && _memory[result.videoId] == report) {
          _memory.remove(result.videoId);
        }
        removed++;
      }
      onResults?.call(results);
      if (removed == 0) break;
    }
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_user == null || isEmpty) {
      _retry?.cancel();
      _retry = null;
    } else {
      _retry ??= Timer.periodic(retryEvery, (_) => flush());
    }
  }

  /// This user's reports, oldest first, after dropping expired ones.
  List<ProgressReport> _all() {
    final user = _user;
    if (user == null) return const [];
    final byVideo = <String, ProgressReport>{..._memory};
    for (final key in _browser.localKeys(_userPrefix(user))) {
      final r = _parse(key);
      if (r == null) continue;
      final mine = byVideo[r.videoId];
      if (mine == null || r.watchedAt.isAfter(mine.watchedAt)) {
        byVideo[r.videoId] = r;
      }
    }
    final cutoff = _now().toUtc().subtract(maxAge);
    final fresh = <ProgressReport>[];
    for (final r in byVideo.values) {
      if (r.watchedAt.isBefore(cutoff)) {
        _browser.removeLocal(_key(user, r.videoId));
        _memory.remove(r.videoId);
      } else {
        fresh.add(r);
      }
    }
    return fresh..sort((a, b) => a.watchedAt.compareTo(b.watchedAt));
  }

  /// The report stored under [key]; a corrupt value is removed.
  ProgressReport? _parse(String key) {
    final raw = _browser.readLocal(key);
    if (raw == null) return null;
    try {
      return ProgressReport.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      _browser.removeLocal(key);
      return null;
    }
  }

  void dispose() {
    _debounce?.cancel();
    _retry?.cancel();
  }
}
