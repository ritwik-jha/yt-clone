import 'package:dio/dio.dart';

import '../core/api_exception.dart';
import '../models/channel.dart';
import '../models/page_result.dart';
import '../models/progress.dart';
import '../models/video.dart';

/// Order for the feed, search, and channel lists.
enum VideoSort {
  latest,
  popular;

  String get wire => name;
}

class VideoService {
  VideoService(this._api);
  final Dio _api;

  Future<PageResult<Video>> feed({
    int page = 1,
    int limit = 10,
    VideoSort sort = VideoSort.latest,
  }) => guardApi(() async {
    final res = await _api.get<Map<String, dynamic>>(
      '/video/feed',
      queryParameters: {'page': page, 'limit': limit, 'sort': sort.wire},
    );
    return PageResult.fromJson(res.data!, Video.fromJson);
  });

  /// Listed videos whose title or description has every word of [query].
  Future<PageResult<Video>> search(
    String query, {
    int page = 1,
    int limit = 10,
    VideoSort sort = VideoSort.latest,
  }) => guardApi(() async {
    final res = await _api.get<Map<String, dynamic>>(
      '/video/search',
      queryParameters: {
        'q': query,
        'page': page,
        'limit': limit,
        'sort': sort.wire,
      },
    );
    return PageResult.fromJson(res.data!, Video.fromJson);
  });

  Future<ChannelListing> channel(
    String userId, {
    int page = 1,
    int limit = 10,
    VideoSort sort = VideoSort.latest,
  }) => guardApi(() async {
    final res = await _api.get<Map<String, dynamic>>(
      '/video/channel/$userId',
      queryParameters: {'page': page, 'limit': limit, 'sort': sort.wire},
    );
    return ChannelListing.fromJson(res.data!);
  });

  Future<PageResult<Video>> mine({int page = 1, int limit = 10}) =>
      guardApi(() async {
        final res = await _api.get<Map<String, dynamic>>(
          '/video/mine',
          queryParameters: {'page': page, 'limit': limit},
        );
        return PageResult.fromJson(res.data!, Video.fromJson);
      });

  Future<Video> detail(String id) => guardApi(() async {
    final res = await _api.get<Map<String, dynamic>>('/video/$id');
    return Video.fromJson(res.data!);
  });

  Future<Progress> progress(String id) => guardApi(() async {
    final res = await _api.get<Map<String, dynamic>>('/video/$id/progress');
    return Progress.fromJson(res.data!);
  });

  Future<Video> update(String id, VideoUpdate changes) => guardApi(() async {
    final res = await _api.patch<Map<String, dynamic>>(
      '/video/$id',
      data: changes.toJson(),
    );
    return Video.fromJson(res.data!);
  });

  Future<void> delete(String id) =>
      guardApi(() => _api.delete<dynamic>('/video/$id'));

  Future<void> recordView(String id) =>
      guardApi(() => _api.post<dynamic>('/video/$id/view'));

  /// Lets this browser stream video [id] for a while: the API sets the
  /// CloudFront signed cookies the CDN asks for. Returns when they stop
  /// working; null when the API doesn't sign (local runs).
  Future<DateTime?> authorizePlayback(String id) => guardApi(() async {
    final res = await _api.post<Map<String, dynamic>>('/video/$id/playback');
    final at = res.data?['expires_at'] as String?;
    return at == null ? null : DateTime.parse(at);
  });

  /// The URL to load for a stream URL the API returned. The API answers
  /// them relative to its own origin (`/media/...`, served by the same
  /// CloudFront distribution); absolute ones pass through.
  String streamUrl(String url) =>
      Uri.parse(_api.options.baseUrl).resolve(url).toString();
}
