import 'package:equatable/equatable.dart';
import 'package:intl/intl.dart';

import '../../core/api_exception.dart';
import '../../core/format.dart';
import '../../models/watch_progress.dart';
import '../feed/feed_state.dart';

class HistoryState extends Equatable {
  const HistoryState({
    this.items = const [],
    this.nextCursor,
    this.status = ListStatus.initial,
    this.error,
    this.unavailable = false,
    this.notice,
  });

  final List<HistoryEntry> items;

  /// Null once the last page is in.
  final String? nextCursor;
  final ListStatus status;
  final ApiException? error;

  /// The backend has no watch history.
  final bool unavailable;

  /// A message for a snack bar (a removal that didn't go through). A new
  /// [Notice] each time, so the same text shows twice.
  final Notice? notice;

  bool get hasMore => nextCursor != null;
  bool get isBusy =>
      status == ListStatus.loading ||
      status == ListStatus.loadingMore ||
      status == ListStatus.refreshing;

  HistoryState copyWith({
    List<HistoryEntry>? items,
    String? nextCursor,
    bool clearCursor = false,
    ListStatus? status,
    ApiException? error,
    bool clearError = false,
    bool? unavailable,
    Notice? notice,
  }) => HistoryState(
    items: items ?? this.items,
    nextCursor: clearCursor ? null : (nextCursor ?? this.nextCursor),
    status: status ?? this.status,
    error: clearError ? null : (error ?? this.error),
    unavailable: unavailable ?? this.unavailable,
    notice: notice,
  );

  @override
  List<Object?> get props => [
    items,
    nextCursor,
    status,
    error,
    unavailable,
    notice,
  ];
}

class Notice {
  Notice(this.message);
  final String message;
}

/// Rows under one day header on the History page.
class HistoryDay extends Equatable {
  const HistoryDay(this.label, this.entries);
  final String label;
  final List<HistoryEntry> entries;

  @override
  List<Object?> get props => [label, entries];
}

/// Groups [entries] (newest first) by the local day they were watched:
/// Today, Yesterday, the weekday for the rest of the last week, then the
/// date.
List<HistoryDay> groupByDay(List<HistoryEntry> entries, {DateTime? now}) {
  final today = _day(now ?? DateTime.now());
  final days = <HistoryDay>[];
  for (final e in entries) {
    final label = dayLabel(e.progress.lastWatchedAt, today: today);
    if (days.isNotEmpty && days.last.label == label) {
      days.last.entries.add(e);
    } else {
      days.add(HistoryDay(label, [e]));
    }
  }
  return days;
}

String dayLabel(DateTime watchedAt, {required DateTime today}) {
  final day = _day(watchedAt.toLocal());
  // Calendar days, not 24-hour spans: DST shifts make those 23 or 25 hours.
  final ago = DateTime.utc(
    today.year,
    today.month,
    today.day,
  ).difference(DateTime.utc(day.year, day.month, day.day)).inDays;
  if (ago <= 0) return 'Today';
  if (ago == 1) return 'Yesterday';
  if (ago < 7) return DateFormat.EEEE().format(day);
  return formatDate(day);
}

DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);
