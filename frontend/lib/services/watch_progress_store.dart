import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api_exception.dart';
import '../models/watch_progress.dart';
import 'history_service.dart';

/// The signed-in user's progress per video, for the bars on thumbnails.
///
/// Thumbnails ask for their video ([watch]); the ids asked for in one turn
/// of the event loop (one frame's build) go out together as
/// `GET /history/positions`, at most [HistoryService.maxBatch] per request,
/// so a page of cards costs one call. Ids already looked up are not asked
/// again. Failures are ignored: the bars are decoration.
///
/// Entries also arrive from this browser's reports, `stale` answers, and
/// the History page ([put]). Signed out, nothing is asked and every bar is
/// empty.
///
/// Reads ([peek]) see every change at once. The listenables the bars watch
/// are updated in a microtask, because changes can come from inside a frame
/// (the watch page reporting as it is disposed), when the tree is locked.
class WatchProgressStore {
  WatchProgressStore(this._service, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final HistoryService _service;
  final DateTime Function() _now;

  /// The backend has no watch history (see [historyUnavailable]).
  void Function()? onUnavailable;

  bool _enabled = false;
  final _active = ValueNotifier(false);
  final _values = <String, WatchProgress?>{};
  final _notifiers = <String, ValueNotifier<WatchProgress?>>{};
  final _changed = <String>{};
  bool _publishing = false;
  final _lookedUpAt = <String, DateTime>{};
  final _queue = <String>{};
  Timer? _batch;

  /// True while signed in (and the backend has history). Thumbnails built
  /// before the session was restored ask for their video when this turns
  /// true.
  ValueListenable<bool> get active => _active;

  /// Signed in: start answering.
  void enable() {
    _enabled = true;
    _schedulePublish();
  }

  /// Signed out, or no history on this backend: empty every bar and forget
  /// what was looked up.
  void disable() {
    _enabled = false;
    _batch?.cancel();
    _batch = null;
    _queue.clear();
    _lookedUpAt.clear();
    for (final id in [..._values.keys]) {
      _set(id, null);
    }
    _schedulePublish();
  }

  /// Progress on [videoId], looked up if it isn't known yet.
  ValueListenable<WatchProgress?> watch(String videoId) {
    final n = _notifiers.putIfAbsent(
      videoId,
      () => ValueNotifier(_values[videoId]),
    );
    _request(videoId);
    return n;
  }

  WatchProgress? peek(String videoId) => _values[videoId];

  /// Whether [videoId] was looked up (or reported) within [maxAge], so its
  /// entry, or the lack of one, can be trusted without asking again.
  bool isFresh(String videoId, Duration maxAge) {
    final at = _lookedUpAt[videoId];
    return at != null && _now().difference(at) <= maxAge;
  }

  void _request(String id) {
    if (!_enabled || _lookedUpAt.containsKey(id) || !_queue.add(id)) return;
    _batch ??= Timer(Duration.zero, _send);
  }

  Future<void> _send() async {
    _batch = null;
    final ids = _queue.toList();
    _queue.clear();
    final at = _now();
    for (final id in ids) {
      _lookedUpAt[id] = at;
    }
    for (var i = 0; i < ids.length; i += HistoryService.maxBatch) {
      final chunk = ids.sublist(
        i,
        i + HistoryService.maxBatch > ids.length
            ? ids.length
            : i + HistoryService.maxBatch,
      );
      try {
        final found = await _service.positions(chunk);
        if (!_enabled) return;
        found.forEach(put);
      } on ApiException catch (e) {
        if (historyUnavailable(e)) {
          onUnavailable?.call();
          return;
        }
        // Ask again next time these thumbnails are built.
        chunk.forEach(_lookedUpAt.remove);
      }
    }
  }

  /// Keeps [progress] if it is newer than what is known.
  void put(WatchProgress progress) {
    if (!_enabled) return;
    final id = progress.videoId;
    _lookedUpAt[id] = _now();
    if (progress.isNewerThan(_values[id])) _set(id, progress);
  }

  /// [videoId] has no history (removed from it).
  void remove(String videoId) {
    _lookedUpAt[videoId] = _now();
    _set(videoId, null);
  }

  /// No video has history any more (history cleared).
  void clear() {
    final at = _now();
    for (final id in {..._values.keys, ..._notifiers.keys}) {
      _lookedUpAt[id] = at;
      _set(id, null);
    }
  }

  void _set(String id, WatchProgress? value) {
    if (value == null) {
      if (_values.remove(id) == null && !_notifiers.containsKey(id)) return;
    } else {
      _values[id] = value;
    }
    _changed.add(id);
    _schedulePublish();
  }

  void _schedulePublish() {
    if (_publishing) return;
    _publishing = true;
    scheduleMicrotask(_publish);
  }

  void _publish() {
    _publishing = false;
    if (_disposed) return;
    for (final id in _changed) {
      _notifiers[id]?.value = _values[id];
    }
    _changed.clear();
    _active.value = _enabled;
  }

  bool _disposed = false;

  void dispose() {
    _disposed = true;
    _batch?.cancel();
    _active.dispose();
    for (final n in _notifiers.values) {
      n.dispose();
    }
  }
}
