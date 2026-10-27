import 'dart:convert';

import 'package:dio/dio.dart';

import '../core/api_exception.dart';
import '../models/watch_progress.dart';

/// Watch history (`/history`). Every call needs a session.
class HistoryService {
  HistoryService(this._api);
  final Dio _api;

  /// Most entries one `POST /history/progress` or positions lookup takes.
  static const maxBatch = 50;

  /// Where a closing tab sends its unsent reports (`Browser.postOnExit`).
  String get exitUrl => '${_api.options.baseUrl}/history/progress';

  /// The body [record] sends, for [exitUrl].
  static String exitBody(List<ProgressReport> reports) => jsonEncode({
    'entries': [for (final r in reports) r.toJson()],
  });

  /// One result per distinct video, in the order sent.
  Future<List<ProgressResult>> record(List<ProgressReport> reports) =>
      guardApi(() async {
        final res = await _api.post<Map<String, dynamic>>(
          '/history/progress',
          data: {
            'entries': [for (final r in reports) r.toJson()],
          },
        );
        return [
          for (final e in res.data!['results'] as List<dynamic>)
            ProgressResult.fromJson(e as Map<String, dynamic>),
        ];
      });

  Future<HistoryPage> list({String? cursor, int limit = 20}) =>
      guardApi(() async {
        final res = await _api.get<Map<String, dynamic>>(
          '/history',
          queryParameters: {'limit': limit, 'cursor': ?cursor},
        );
        return HistoryPage.fromJson(res.data!);
      });

  /// Progress on up to [maxBatch] videos; unwatched ones are left out.
  Future<List<WatchProgress>> positions(List<String> videoIds) =>
      guardApi(() async {
        final res = await _api.get<Map<String, dynamic>>(
          '/history/positions',
          queryParameters: {'video_ids': videoIds.join(',')},
        );
        return [
          for (final e in res.data!['items'] as List<dynamic>)
            WatchProgress.fromJson(e as Map<String, dynamic>),
        ];
      });

  Future<void> remove(String videoId) =>
      guardApi(() => _api.delete<dynamic>('/history/$videoId'));

  Future<void> clear() => guardApi(() => _api.delete<dynamic>('/history'));
}

/// A backend from before watch history answers its paths with FastAPI's
/// generic 404, so the app can turn the feature off instead of retrying.
bool historyUnavailable(ApiException e) =>
    e.statusCode == 404 && e.code == 'not_found';
