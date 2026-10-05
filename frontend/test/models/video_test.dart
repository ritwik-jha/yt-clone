import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ytp_app/models/page_result.dart';
import 'package:ytp_app/models/progress.dart';
import 'package:ytp_app/models/video.dart';

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

  test('playbackUrl: HLS on iOS, DASH on Android; null hls_url on iOS', () {
    final v = page.items.first;
    expect(v.playbackUrlFor(TargetPlatform.iOS), endsWith('master.m3u8'));
    expect(v.playbackUrlFor(TargetPlatform.android), endsWith('manifest.mpd'));
    expect(page.items.last.playbackUrlFor(TargetPlatform.iOS), isNull);
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
