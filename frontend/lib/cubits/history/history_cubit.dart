import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/api_exception.dart';
import '../../models/watch_progress.dart';
import '../../services/history_service.dart';
import '../../services/history_sync.dart';
import '../feed/feed_state.dart';
import 'history_state.dart';

/// The History page: the signed-in user's history, newest first, paged by
/// cursor (`GET /history`).
///
/// Removing an entry hides it at once and deletes it on the server only
/// after [undoWindow] (or when the page closes), so *Undo* just puts it
/// back. Re-sending the entry instead would not work for anything watched
/// more than 30 days ago: the server answers such a report `expired`.
class HistoryCubit extends Cubit<HistoryState> {
  HistoryCubit(
    this._sync, {
    this.limit = 20,
    this.undoWindow = const Duration(seconds: 5),
  }) : super(const HistoryState());

  final HistorySync _sync;
  final int limit;
  final Duration undoWindow;
  final _pending = <String, _Removal>{};

  HistoryService get _service => _sync.service;

  Future<void> load() async {
    emit(state.copyWith(status: ListStatus.loading, clearError: true));
    await _fetch(replace: true);
  }

  Future<void> refresh() async {
    if (state.isBusy) return;
    emit(state.copyWith(status: ListStatus.refreshing, clearError: true));
    await _fetch(replace: true);
  }

  Future<void> loadMore() async {
    if (state.isBusy || !state.hasMore || state.status == ListStatus.failure) {
      return;
    }
    emit(state.copyWith(status: ListStatus.loadingMore));
    await _fetch(replace: false);
  }

  Future<void> _fetch({required bool replace}) async {
    try {
      final page = await _service.list(
        cursor: replace ? null : state.nextCursor,
        limit: limit,
      );
      if (isClosed) return;
      for (final e in page.items) {
        _sync.store.put(e.progress);
      }
      final seen = <String>{if (!replace) ...state.items.map(_id)};
      emit(
        state.copyWith(
          items: [
            if (!replace) ...state.items,
            for (final e in page.items)
              // Hidden while its removal may still be undone.
              if (!_pending.containsKey(_id(e)) && seen.add(_id(e))) e,
          ],
          nextCursor: page.nextCursor,
          clearCursor: page.nextCursor == null,
          status: ListStatus.success,
          clearError: true,
        ),
      );
    } on ApiException catch (e) {
      if (isClosed) return;
      if (historyUnavailable(e)) {
        _sync.markUnavailable();
        emit(state.copyWith(status: ListStatus.success, unavailable: true));
        return;
      }
      emit(
        state.copyWith(
          status: replace && state.items.isEmpty
              ? ListStatus.failure
              : ListStatus.success,
          error: e,
        ),
      );
    }
  }

  /// Hides [videoId] now; deletes it after [undoWindow] unless [undo]ne.
  void remove(String videoId) {
    final index = state.items.indexWhere((e) => _id(e) == videoId);
    if (index < 0) return;
    final entry = state.items[index];
    _pending[videoId]?.timer.cancel();
    _pending[videoId] = _Removal(
      entry,
      index,
      Timer(undoWindow, () => _commit(videoId)),
    );
    _sync.forget(videoId);
    emit(state.copyWith(items: [...state.items]..removeAt(index)));
  }

  /// Puts [videoId] back where it was.
  void undo(String videoId) {
    final removal = _pending.remove(videoId);
    if (removal == null) return;
    removal.timer.cancel();
    _restore(removal);
  }

  void _restore(_Removal removal) {
    _sync.store.put(removal.entry.progress);
    final items = [...state.items];
    items.insert(removal.index.clamp(0, items.length), removal.entry);
    if (!isClosed) emit(state.copyWith(items: items));
  }

  Future<void> _commit(String videoId) async {
    final removal = _pending.remove(videoId);
    if (removal == null) return;
    try {
      await _service.remove(videoId);
    } on ApiException catch (e) {
      if (isClosed) return;
      _restore(removal);
      emit(state.copyWith(notice: Notice("Couldn't remove it: ${e.message}")));
    }
  }

  /// Deletes everything, here and on the server, and anything this browser
  /// hasn't sent yet.
  Future<void> clear() async {
    for (final r in _pending.values) {
      r.timer.cancel();
    }
    _pending.clear();
    try {
      await _service.clear();
    } on ApiException catch (e) {
      if (isClosed) return;
      emit(state.copyWith(notice: Notice("Couldn't clear it: ${e.message}")));
      return;
    }
    _sync.forgetAll();
    if (isClosed) return;
    emit(state.copyWith(items: const [], clearCursor: true));
  }

  static String _id(HistoryEntry e) => e.video.id;

  @override
  Future<void> close() {
    // Leaving the page ends the undo window.
    for (final id in [..._pending.keys]) {
      _pending[id]!.timer.cancel();
      _service.remove(id).ignore();
    }
    _pending.clear();
    return super.close();
  }
}

class _Removal {
  _Removal(this.entry, this.index, this.timer);
  final HistoryEntry entry;
  final int index;
  final Timer timer;
}
