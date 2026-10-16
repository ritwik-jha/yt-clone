import 'package:flutter/foundation.dart';

import 'browser_stub.dart'
    if (dart.library.js_interop) 'browser_web.dart'
    as impl;

/// A file the user picked or the app made (a captured thumbnail). The bytes
/// stay in the browser: [handle] is the JS `Blob`/`File`, which uploads
/// stream from directly, so a multi-GB video is never copied into Dart.
class PickedFile {
  const PickedFile({
    required this.name,
    required this.size,
    required this.type,
    required this.handle,
  });

  final String name;
  final int size;

  /// MIME type as the browser reports it; may be empty.
  final String type;
  final Object handle;
}

/// A presigned PUT failed.
class UploadFailure implements Exception {
  const UploadFailure({this.status});

  /// HTTP status, or null when the request never completed (network).
  final int? status;

  @override
  String toString() => 'UploadFailure($status)';
}

/// The upload was aborted through its [UploadCancel].
class UploadAborted implements Exception {
  const UploadAborted();
}

/// Aborts an in-flight [Browser.put].
class UploadCancel {
  void Function()? _onCancel;
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _onCancel?.call();
  }

  /// Called by the transport; runs [abort] at once if already cancelled.
  void bind(void Function() abort) {
    _onCancel = abort;
    if (_cancelled) abort();
  }
}

typedef UploadProgress = void Function(int sent, int total);

/// The browser APIs the app needs beyond Flutter: file selection, frame
/// capture, uploads to presigned URLs, and the leave-page warning.
/// Pages and cubits take it from the widget tree, so tests swap in a fake.
abstract class Browser {
  /// Opens the file chooser. Null when the user cancels.
  Future<PickedFile?> pickFile({required String accept});

  /// Files dropped anywhere on the page call [onFile] until the returned
  /// function is called.
  void Function() listenForDrops(void Function(PickedFile file) onFile);

  /// A JPEG frame from near the start of [video], at most 1280×720. Null
  /// when the browser can't decode the file.
  Future<PickedFile?> captureFrame(PickedFile video);

  /// [image] re-encoded as a JPEG of at most 1280×720. Null when it can't
  /// be decoded.
  Future<PickedFile?> toJpeg(PickedFile image);

  /// A `blob:` URL for previewing [file]; release it with [revokeUrl].
  String objectUrl(PickedFile file);
  void revokeUrl(String url);

  /// PUTs [file] to a presigned S3 URL. The Content-Type must be the one
  /// the URL was signed for. Throws [UploadFailure] or [UploadAborted].
  Future<void> put(
    String url,
    PickedFile file, {
    required String contentType,
    UploadProgress? onProgress,
    UploadCancel? cancel,
  });

  /// While on, closing or reloading the tab asks the user to confirm.
  void setLeaveWarning(bool on);

  /// Whether the page is fullscreen. The user can leave with Esc at any
  /// time, so listen rather than assume.
  ValueListenable<bool> get fullscreen;
  Future<void> setFullscreen(bool on);
}

Browser createBrowser() => impl.createBrowser();
