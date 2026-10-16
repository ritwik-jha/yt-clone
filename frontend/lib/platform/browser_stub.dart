import 'package:flutter/foundation.dart';

import 'browser.dart';

/// Used off the web (unit and widget tests on the VM). Tests that need
/// browser behaviour provide their own [Browser].
Browser createBrowser() => _NoBrowser();

class _NoBrowser implements Browser {
  final _fullscreen = ValueNotifier(false);

  @override
  ValueListenable<bool> get fullscreen => _fullscreen;

  @override
  Future<void> setFullscreen(bool on) async => _fullscreen.value = on;

  @override
  Future<PickedFile?> pickFile({required String accept}) async => null;

  @override
  void Function() listenForDrops(void Function(PickedFile file) onFile) =>
      () {};

  @override
  Future<PickedFile?> captureFrame(PickedFile video) async => null;

  @override
  Future<PickedFile?> toJpeg(PickedFile image) async => null;

  @override
  String objectUrl(PickedFile file) => '';

  @override
  void revokeUrl(String url) {}

  @override
  Future<void> put(
    String url,
    PickedFile file, {
    required String contentType,
    UploadProgress? onProgress,
    UploadCancel? cancel,
  }) => throw UnsupportedError('Uploads need a browser');

  @override
  void setLeaveWarning(bool on) {}
}
