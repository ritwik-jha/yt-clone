import 'package:intl/intl.dart';

/// `m:ss` or `h:mm:ss`.
String formatDuration(num seconds) {
  final total = seconds.round();
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final ss = s.toString().padLeft(2, '0');
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$ss';
  return '$m:$ss';
}

String formatViews(int count) {
  final n = NumberFormat.compact().format(count);
  return count == 1 ? '1 view' : '$n views';
}

String formatViewsFull(int count) =>
    '${NumberFormat.decimalPattern().format(count)} ${count == 1 ? 'view' : 'views'}';

String timeAgo(DateTime then, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).difference(then);
  String unit(int n, String s) => '$n $s${n == 1 ? '' : 's'} ago';
  if (diff.inDays >= 365) return unit(diff.inDays ~/ 365, 'year');
  if (diff.inDays >= 30) return unit(diff.inDays ~/ 30, 'month');
  if (diff.inDays >= 7) return unit(diff.inDays ~/ 7, 'week');
  if (diff.inDays >= 1) return unit(diff.inDays, 'day');
  if (diff.inHours >= 1) return unit(diff.inHours, 'hour');
  if (diff.inMinutes >= 1) return unit(diff.inMinutes, 'minute');
  return 'just now';
}

String formatBytes(int bytes) {
  if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
  if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
  if (bytes >= 1 << 10) return '${(bytes / (1 << 10)).toStringAsFixed(0)} KB';
  return '$bytes B';
}

String formatJoined(DateTime d) =>
    'Joined ${DateFormat('MMMM yyyy').format(d)}';
