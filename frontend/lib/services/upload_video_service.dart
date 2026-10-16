import 'package:dio/dio.dart';

import '../core/api_exception.dart';
import '../models/saved_video.dart';
import '../models/video.dart';
import '../platform/browser.dart';

class PresignedUpload {
  const PresignedUpload({required this.url, required this.key});
  final String url;
  final String key;
}

/// Presigned-URL upload calls (plan §7). The PUTs go from the browser
/// straight to S3, with no cookies and no Authorization header.
class UploadVideoService {
  UploadVideoService({required this._api, required this._browser});

  final Dio _api;
  final Browser _browser;

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

  /// PUTs [file]. The Content-Type must be exactly what the URL was
  /// presigned for. Throws [ApiException], or [UploadAborted] on cancel.
  Future<void> put(
    String url,
    PickedFile file,
    String contentType, {
    UploadProgress? onProgress,
    UploadCancel? cancel,
  }) async {
    try {
      await _browser.put(
        url,
        file,
        contentType: contentType,
        onProgress: onProgress,
        cancel: cancel,
      );
    } on UploadFailure catch (e) {
      throw ApiException(
        kind: e.status == null ? ApiErrorKind.network : ApiErrorKind.server,
        statusCode: e.status,
        code: e.status == 403 ? 'upload_forbidden' : null,
        message: e.status == null
            ? 'Upload interrupted. Check your connection and retry.'
            : 'Upload failed (${e.status}).',
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
