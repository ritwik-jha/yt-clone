import 'package:dio/dio.dart';

import '../core/api_exception.dart';
import '../models/page_result.dart';
import '../models/progress.dart';
import '../models/video.dart';

class VideoService {
  VideoService(this._api);
  final Dio _api;

  Future<PageResult<Video>> feed({int page = 1, int limit = 10}) =>
      guardApi(() async {
        final res = await _api.get<Map<String, dynamic>>(
          '/video/feed',
          queryParameters: {'page': page, 'limit': limit},
        );
        return PageResult.fromJson(res.data!, Video.fromJson);
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
}
