import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ytp_app/models/page_result.dart';
import 'package:ytp_app/models/progress.dart';
import 'package:ytp_app/models/video.dart';
import 'package:ytp_app/platform/video_player.dart';

void main() {
  final json = jsonDecode(
    File('test/fixtures/feed_page.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final page = PageResult.fromJson(json, Video.fromJson);

  test('feed page parses; feed items default to PUBLIC + COMPLETED', () {
    expect(page.items, hasLength(2));
    final v = page.items.first;
    expect(v.effectiveStatus, VideoStatus.completed);
    expect(v.effectiveVisibility, VideoVisibility.public);
    expect(v.durationSeconds, 125.4);
    expect(page.items.last.durationSeconds, isNull);
    expect(page.hasMore, isFalse);
  });

  test('playbackSource: HLS when there is one, else DASH, else none', () {
    expect(
      page.items.first.playbackSource,
      const PlaybackSource(
        'https://cdn.example.com/1/dash/master.m3u8',
        StreamKind.hls,
      ),
    );
    // Transcoded before the pipeline wrote HLS.
    expect(
      page.items.last.playbackSource,
      const PlaybackSource(
        'https://cdn.example.com/2/dash/manifest.mpd',
        StreamKind.dash,
      ),
    );
    final unfinished = Video.fromJson({
      ...(json['items'] as List).first as Map<String, dynamic>,
      'manifest_url': null,
      'hls_url': null,
    });
    expect(unfinished.playbackSource, isNull);
    expect(unfinished.isPlayable, isFalse);
  });

  test('unknown enum values do not crash', () {
    expect(VideoStatus.parse('SOMETHING_NEW'), VideoStatus.unknown);
    expect(VideoVisibility.parse('hidden'), VideoVisibility.unknown);
    expect(VideoVisibility.parse('public'), VideoVisibility.public);
  });

  test('VideoUpdate serialises only changed fields', () {
    expect(const VideoUpdate(title: 'x').toJson(), {'title': 'x'});
    expect(
      const VideoUpdate(
        description: '',
        visibility: VideoVisibility.private,
      ).toJson(),
      {'description': '', 'visibility': 'PRIVATE'},
    );
    expect(const VideoUpdate().isEmpty, isTrue);
  });

  test('PageResult.hasMore', () {
    const p = PageResult<int>(total: 25, page: 2, limit: 10, items: []);
    expect(p.hasMore, isTrue);
    const q = PageResult<int>(total: 25, page: 3, limit: 10, items: []);
    expect(q.hasMore, isFalse);
  });

  test('progress parses', () {
    final p = Progress.fromJson({
      'video_id': 'a',
      'percent': 80,
      'status': 'PROCESSING',
    });
    expect(p.percent, 80);
    expect(p.status, VideoStatus.processing);
  });
}
