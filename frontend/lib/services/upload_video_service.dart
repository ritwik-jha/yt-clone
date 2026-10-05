import 'dart:io';

import 'package:dio/dio.dart';

import '../core/api_exception.dart';
import '../models/saved_video.dart';
import '../models/video.dart';

class PresignedUpload {
  const PresignedUpload({required this.url, required this.key});
  final String url;
  final String key;
}

/// Presigned-URL upload calls (plan §7). The S3 client never carries an
/// Authorization header.
class UploadVideoService {
  UploadVideoService({required this._api, required this._s3});

  final Dio _api;
  final Dio _s3;

  Future<PresignedUpload> thumbnailUrl() => guardApi(() async {
    final res = await _api.get<Map<String, dynamic>>(
      '/upload/video/url/thumbnail',
    );
    return PresignedUpload(
      url: res.data!['url'] as String,
      key: res.data!['thumbnail_id'] as String,
    );
  });

  Future<PresignedUpload> videoUrl() => guardApi(() async {
    final res = await _api.get<Map<String, dynamic>>('/upload/video/url');
    return PresignedUpload(
      url: res.data!['url'] as String,
      key: res.data!['video_id'] as String,
    );
  });

  /// Streams [file] with an explicit Content-Length. The Content-Type must be
  /// exactly what the URL was presigned for.
  Future<void> put(
    String url,
    File file,
    String contentType, {
    ProgressCallback? onProgress,
    CancelToken? cancel,
  }) async {
    try {
      await _s3.put<void>(
        url,
        data: file.openRead(),
        options: Options(
          headers: {
            Headers.contentTypeHeader: contentType,
            Headers.contentLengthHeader: await file.length(),
          },
        ),
        onSendProgress: onProgress,
        cancelToken: cancel,
      );
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) rethrow;
      throw ApiException(
        kind: e.response == null ? ApiErrorKind.network : ApiErrorKind.server,
        statusCode: e.response?.statusCode,
        code: e.response?.statusCode == 403 ? 'upload_forbidden' : null,
        message: e.response == null
            ? "Upload interrupted. Check your connection and retry."
            : 'Upload failed (${e.response?.statusCode}).',
      );
    }
  }

  Future<SavedVideo> save({
    required String title,
    required String description,
    required VideoVisibility visibility,
    required String videoKey,
    required String thumbnailKey,
  }) => guardApi(() async {
    final res = await _api.post<Map<String, dynamic>>(
      '/upload/video/save',
      data: {
        'title': title.trim(),
        if (description.trim().isNotEmpty) 'description': description.trim(),
        'visibility': visibility.wire,
        's3_key': videoKey,
        'thumbnail_s3_key': thumbnailKey,
      },
    );
    return SavedVideo.fromJson(res.data!);
  });
}
