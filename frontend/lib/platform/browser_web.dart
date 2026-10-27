import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import 'browser.dart';

Browser createBrowser() => _WebBrowser();

const _maxThumbWidth = 1280;
const _maxThumbHeight = 720;
const _jpegQuality = 0.85;

class _WebBrowser implements Browser {
  _WebBrowser() {
    web.document.addEventListener(
      'fullscreenchange',
      ((
        web.Event _,
      ) => _fullscreen.value = web.document.fullscreenElement != null).toJS,
    );
  }

  JSFunction? _beforeUnload;
  final _fullscreen = ValueNotifier(false);

  @override
  ValueListenable<bool> get fullscreen => _fullscreen;

  @override
  Future<void> setFullscreen(bool on) async {
    try {
      if (on && web.document.fullscreenElement == null) {
        // The whole page, not the <video>: the app draws its own controls,
        // and the watch page fills the screen with the player while on.
        await web.document.documentElement!.requestFullscreen().toDart;
      } else if (!on && web.document.fullscreenElement != null) {
        await web.document.exitFullscreen().toDart;
      }
    } on Object {
      // Refused (no user gesture, or an iframe without allowfullscreen).
    }
  }

  PickedFile _wrap(web.File f) =>
      PickedFile(name: f.name, size: f.size, type: f.type, handle: f);

  @override
  Future<PickedFile?> pickFile({required String accept}) {
    final input = web.HTMLInputElement()
      ..type = 'file'
      ..accept = accept;
    final done = Completer<PickedFile?>();
    void finish(PickedFile? file) {
      if (!done.isCompleted) done.complete(file);
    }

    input.addEventListener(
      'change',
      (web.Event _) {
        final file = input.files?.item(0);
        finish(file == null ? null : _wrap(file));
      }.toJS,
    );
    input.addEventListener('cancel', ((web.Event _) => finish(null)).toJS);
    input.click();
    return done.future;
  }

  @override
  void Function() listenForDrops(void Function(PickedFile file) onFile) {
    // The page must cancel dragover for the browser to allow a drop at all.
    void over(web.DragEvent e) => e.preventDefault();
    void drop(web.DragEvent e) {
      e.preventDefault();
      final file = e.dataTransfer?.files.item(0);
      if (file != null) onFile(_wrap(file));
    }

    final overJs = over.toJS;
    final dropJs = drop.toJS;
    web.window.addEventListener('dragover', overJs);
    web.window.addEventListener('drop', dropJs);
    return () {
      web.window.removeEventListener('dragover', overJs);
      web.window.removeEventListener('drop', dropJs);
    };
  }

  @override
  Future<PickedFile?> captureFrame(PickedFile video) async {
    final url = web.URL.createObjectURL(video.handle as web.Blob);
    final el = web.HTMLVideoElement()
      ..muted = true
      ..preload = 'auto'
      ..src = url;
    try {
      await _event(el, 'loadedmetadata');
      final duration = el.duration;
      final at = duration.isFinite && duration > 0
          ? math.min(1.0, duration / 3)
          : 0.0;
      el.currentTime = at;
      await _event(el, 'seeked');
      if (el.videoWidth == 0 || el.videoHeight == 0) return null;
      return await _jpeg(el, el.videoWidth, el.videoHeight, 'thumbnail.jpg');
    } on Object {
      return null;
    } finally {
      el.removeAttribute('src');
      el.load();
      web.URL.revokeObjectURL(url);
    }
  }

  @override
  Future<PickedFile?> toJpeg(PickedFile image) async {
    try {
      final bitmap = await web.window
          .createImageBitmap(image.handle as web.Blob)
          .toDart;
      try {
        return await _jpeg(
          bitmap,
          bitmap.width,
          bitmap.height,
          'thumbnail.jpg',
        );
      } finally {
        bitmap.close();
      }
    } on Object {
      return null;
    }
  }

  /// Draws [source] scaled to fit 1280×720 and encodes it as JPEG.
  Future<PickedFile?> _jpeg(
    web.CanvasImageSource source,
    int width,
    int height,
    String name,
  ) async {
    final scale = math.min(
      1.0,
      math.min(_maxThumbWidth / width, _maxThumbHeight / height),
    );
    final w = math.max(1, (width * scale).round());
    final h = math.max(1, (height * scale).round());
    final canvas = web.HTMLCanvasElement()
      ..width = w
      ..height = h;
    final ctx = canvas.getContext('2d')! as web.CanvasRenderingContext2D;
    ctx.drawImage(source, 0, 0, w, h);
    final done = Completer<web.Blob?>();
    canvas.toBlob(
      (web.Blob? blob) {
        done.complete(blob);
      }.toJS,
      'image/jpeg',
      _jpegQuality.toJS,
    );
    final blob = await done.future;
    if (blob == null) return null;
    return PickedFile(
      name: name,
      size: blob.size,
      type: blob.type,
      handle: blob,
    );
  }

  @override
  String objectUrl(PickedFile file) =>
      web.URL.createObjectURL(file.handle as web.Blob);

  @override
  void revokeUrl(String url) => web.URL.revokeObjectURL(url);

  @override
  Future<void> put(
    String url,
    PickedFile file, {
    required String contentType,
    UploadProgress? onProgress,
    UploadCancel? cancel,
  }) {
    final done = Completer<void>();
    final xhr = web.XMLHttpRequest()
      ..open('PUT', url)
      ..setRequestHeader('Content-Type', contentType);
    if (onProgress != null) {
      xhr.upload.addEventListener(
        'progress',
        (web.ProgressEvent e) {
          onProgress(e.loaded, e.lengthComputable ? e.total : file.size);
        }.toJS,
      );
    }
    xhr.addEventListener(
      'load',
      (web.Event _) {
        if (xhr.status >= 200 && xhr.status < 300) {
          done.complete();
        } else {
          done.completeError(UploadFailure(status: xhr.status));
        }
      }.toJS,
    );
    xhr.addEventListener(
      'error',
      ((web.Event _) => done.completeError(const UploadFailure())).toJS,
    );
    xhr.addEventListener(
      'abort',
      (web.Event _) {
        if (!done.isCompleted) done.completeError(const UploadAborted());
      }.toJS,
    );
    // abort() before send() fires no event, so never send a cancelled one.
    if (cancel?.isCancelled ?? false) {
      return Future.error(const UploadAborted());
    }
    cancel?.bind(() => xhr.abort());
    xhr.send(file.handle as web.Blob);
    return done.future;
  }

  @override
  void setLeaveWarning(bool on) {
    if (on && _beforeUnload == null) {
      _beforeUnload = (web.BeforeUnloadEvent e) {
        e.preventDefault();
        e.returnValue = '';
      }.toJS;
      web.window.addEventListener('beforeunload', _beforeUnload);
    } else if (!on && _beforeUnload != null) {
      web.window.removeEventListener('beforeunload', _beforeUnload);
      _beforeUnload = null;
    }
  }

  // Storage can throw (SecurityError) when the browser blocks it.
  web.Storage? get _storage {
    try {
      return web.window.localStorage;
    } on Object {
      return null;
    }
  }

  @override
  String? readLocal(String key) {
    try {
      return _storage?.getItem(key);
    } on Object {
      return null;
    }
  }

  @override
  void writeLocal(String key, String value) {
    try {
      _storage?.setItem(key, value);
    } on Object {
      // Full or blocked: the caller keeps its own copy.
    }
  }

  @override
  void removeLocal(String key) {
    try {
      _storage?.removeItem(key);
    } on Object {
      // Blocked.
    }
  }

  @override
  List<String> localKeys(String prefix) {
    final storage = _storage;
    if (storage == null) return const [];
    try {
      return [
        for (var i = 0; i < storage.length; i++)
          if (storage.key(i) case final k? when k.startsWith(prefix)) k,
      ];
    } on Object {
      return const [];
    }
  }

  @override
  void Function() listenForVisibility({
    required void Function() onHidden,
    required void Function() onVisible,
  }) {
    final onChange = ((web.Event _) {
      if (web.document.visibilityState == 'hidden') {
        onHidden();
      } else {
        onVisible();
      }
    }).toJS;
    final onPageHide = ((web.Event _) => onHidden()).toJS;
    web.document.addEventListener('visibilitychange', onChange);
    web.window.addEventListener('pagehide', onPageHide);
    return () {
      web.document.removeEventListener('visibilitychange', onChange);
      web.window.removeEventListener('pagehide', onPageHide);
    };
  }

  @override
  void postOnExit(String url, String json) {
    try {
      web.window.fetch(
        url.toJS,
        web.RequestInit(
          method: 'POST',
          keepalive: true,
          credentials: 'include',
          headers: {'Content-Type': 'application/json'}.jsify()! as JSObject,
          body: json.toJS,
        ),
      );
    } on Object {
      // Best effort: the outbox sends it again on the next visit.
    }
  }
}

/// Completes on [type]; throws on the element's `error` event or after
/// [timeout].
Future<void> _event(
  web.EventTarget target,
  String type, {
  Duration timeout = const Duration(seconds: 15),
}) {
  final done = Completer<void>();
  late final JSFunction onEvent;
  late final JSFunction onError;
  void cleanup() {
    target.removeEventListener(type, onEvent);
    target.removeEventListener('error', onError);
  }

  onEvent = (web.Event _) {
    cleanup();
    if (!done.isCompleted) done.complete();
  }.toJS;
  onError = (web.Event _) {
    cleanup();
    if (!done.isCompleted) done.completeError(StateError('$type failed'));
  }.toJS;
  target.addEventListener(type, onEvent);
  target.addEventListener('error', onError);
  return done.future.timeout(
    timeout,
    onTimeout: () {
      cleanup();
      throw TimeoutException(type, timeout);
    },
  );
}
