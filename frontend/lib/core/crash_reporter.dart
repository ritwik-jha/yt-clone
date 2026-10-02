import 'package:flutter/foundation.dart';

/// Removes anything that looks like a credential before an error is logged or
/// handed to a crash-reporting backend (PLAN §9: tokens never leave the app).
String scrubSecrets(String input) => input
    .replaceAllMapped(
      RegExp(r'(access_token|refresh_token)=[^;\s]+', caseSensitive: false),
      (m) => '${m[1]}=<redacted>',
    )
    .replaceAll(
      RegExp(r'Bearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
      'Bearer <redacted>',
    )
    // Presigned URLs are credentials for their lifetime.
    .replaceAllMapped(
      RegExp(r'(X-Amz-[A-Za-z-]+|Signature)=[^&\s"]+', caseSensitive: false),
      (m) => '${m[1]}=<redacted>',
    )
    // JWT-shaped strings.
    .replaceAll(
      RegExp(r'eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*'),
      '<jwt>',
    );

/// Sink for scrubbed errors. Swap in Crashlytics/Sentry here; they only ever
/// see the scrubbed text.
typedef CrashSink = void Function(String message, StackTrace? stack);

CrashSink crashSink = (message, stack) {
  if (kDebugMode) debugPrint('[error] $message');
};

void reportError(Object error, StackTrace? stack) {
  crashSink(scrubSecrets(error.toString()), stack);
}

void installCrashReporting() {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    reportError(details.exception, details.stack);
    previous?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    reportError(error, stack);
    return true;
  };
}
