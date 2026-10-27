import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ytp_app/core/api_exception.dart';
import 'package:ytp_app/models/watch_progress.dart';
import 'package:ytp_app/services/history_service.dart';

/// Answers every request with [status] and [body]; records what was sent.
class _Server implements HttpClientAdapter {
  int status = 200;
  Object? body = const <String, dynamic>{};
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _progressJson(String id, int pos) => {
  'video_id': id,
  'position_seconds': pos,
  'duration_seconds': 600,
  'completed': false,
  'last_watched_at': '2026-10-03T10:00:00Z',
};

void main() {
  late _Server server;
  late HistoryService service;

  setUp(() {
    server = _Server();
    service = HistoryService(
      Dio(BaseOptions(baseUrl: 'https://app.test'))..httpClientAdapter = server,
    );
  });

  test('record sends the batch and parses each result', () async {
    server.body = {
      'results': [
        {'video_id': 'a', 'result': 'saved', 'progress': _progressJson('a', 5)},
        {'video_id': 'b', 'result': 'stale', 'progress': _progressJson('b', 9)},
        {'video_id': 'c', 'result': 'not_found', 'progress': null},
        {'video_id': 'd', 'result': 'expired', 'progress': null},
      ],
    };
    final results = await service.record([
      ProgressReport(
        videoId: 'a',
        positionSeconds: 5,
        durationSeconds: 600,
        watchedAt: DateTime.utc(2026, 10, 3, 10),
      ),
    ]);
    final sent = server.requests.single;
    expect((sent.method, sent.path), ('POST', '/history/progress'));
    expect(sent.data, {
      'entries': [
        {
          'video_id': 'a',
          'position_seconds': 5,
          'duration_seconds': 600,
          'watched_at': '2026-10-03T10:00:00.000Z',
        },
      ],
    });
    expect(results.map((r) => r.outcome), [
      ProgressOutcome.saved,
      ProgressOutcome.stale,
      ProgressOutcome.notFound,
      ProgressOutcome.expired,
    ]);
    expect(results[1].progress!.positionSeconds, 9);
  });

  test('list passes the cursor through, and only when there is one', () async {
    server.body = {
      'items': [
        {
          'video': {
            'id': 'a',
            'title': 'A',
            'thumbnail_url': 'https://t/a',
            'views_count': 1,
            'creator': {'id': 'u', 'name': 'U'},
            'created_at': '2026-01-01T00:00:00Z',
          },
          'progress': _progressJson('a', 5),
        },
      ],
      'next_cursor': 'abc',
    };
    final page = await service.list(limit: 2);
    expect(server.requests.last.queryParameters, {'limit': 2});
    expect(page.items.single.video.title, 'A');
    expect(page.items.single.progress.positionSeconds, 5);
    expect(page.nextCursor, 'abc');

    server.body = {'items': [], 'next_cursor': null};
    final last = await service.list(cursor: 'abc');
    expect(server.requests.last.queryParameters, {
      'limit': 20,
      'cursor': 'abc',
    });
    expect(last.nextCursor, isNull);
  });

  test('positions joins the ids', () async {
    server.body = {
      'items': [_progressJson('a', 5)],
    };
    final found = await service.positions(['a', 'b']);
    expect(server.requests.last.path, '/history/positions');
    expect(server.requests.last.queryParameters, {'video_ids': 'a,b'});
    expect(found.single.videoId, 'a');
  });

  test('remove and clear', () async {
    server.status = 204;
    server.body = null;
    await service.remove('a');
    await service.clear();
    expect(
      [for (final r in server.requests) (r.method, r.path)],
      [('DELETE', '/history/a'), ('DELETE', '/history')],
    );
  });

  test('the exit URL and body match what record sends', () {
    expect(service.exitUrl, 'https://app.test/history/progress');
    final body = jsonDecode(
      HistoryService.exitBody([
        ProgressReport(
          videoId: 'a',
          positionSeconds: 1,
          watchedAt: DateTime.utc(2026),
        ),
      ]),
    );
    expect(body, {
      'entries': [
        {
          'video_id': 'a',
          'position_seconds': 1,
          'watched_at': '2026-01-01T00:00:00.000Z',
        },
      ],
    });
  });

  test(
    "a backend without history is told apart from a missing video",
    () async {
      server
        ..status = 404
        ..body = {'detail': 'Not Found', 'code': 'not_found'};
      final e = await service
          .positions(['a'])
          .then<ApiException?>(
            (_) => null,
            onError: (Object e) => e as ApiException,
          );
      expect(historyUnavailable(e!), isTrue);
      expect(
        historyUnavailable(
          ApiException.fromResponse(404, {'code': 'video_not_found'}),
        ),
        isFalse,
      );
      expect(
        historyUnavailable(
          ApiException.fromResponse(400, {'code': 'not_found'}),
        ),
        isFalse,
      );
    },
  );
}
