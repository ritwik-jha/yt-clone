import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ytp_app/core/api_exception.dart';
import 'package:ytp_app/services/video_service.dart';

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

void main() {
  late _Server server;
  late VideoService service;

  setUp(() {
    server = _Server();
    service = VideoService(
      Dio(BaseOptions(baseUrl: 'https://app.test'))..httpClientAdapter = server,
    );
  });

  group('authorizePlayback', () {
    test('posts for the video and parses the expiry', () async {
      server.body = {'expires_at': '2026-10-27T13:00:00Z'};
      final at = await service.authorizePlayback('v1');
      final sent = server.requests.single;
      expect((sent.method, sent.path), ('POST', '/video/v1/playback'));
      expect(at, DateTime.utc(2026, 10, 27, 13));
    });

    test('null when the API does not sign', () async {
      server.body = {'expires_at': null};
      expect(await service.authorizePlayback('v1'), isNull);
    });

    test('a refused video is an ApiException', () async {
      server
        ..status = 404
        ..body = {'code': 'video_not_found', 'detail': 'Video not found'};
      await expectLater(
        service.authorizePlayback('v1'),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'video_not_found'),
        ),
      );
    });
  });

  test('stream URLs resolve against the API origin', () {
    expect(
      service.streamUrl('/media/v1/dash/master.m3u8'),
      'https://app.test/media/v1/dash/master.m3u8',
    );
    expect(
      service.streamUrl('https://cdn.example/v1/master.m3u8'),
      'https://cdn.example/v1/master.m3u8',
    );
  });
}
