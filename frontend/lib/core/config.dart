/// Build-time settings (`--dart-define` / `--dart-define-from-file`).
class AppConfig {
  /// The API's origin, e.g. `https://api.example.com`. Leave it empty when
  /// the app is served from the API's own origin (one CloudFront or ALB in
  /// front of both): requests then go to the page's origin.
  static const apiBaseUrl = String.fromEnvironment('API_BASE_URL');

  static const maxUploadBytes = int.fromEnvironment(
    'MAX_UPLOAD_BYTES',
    defaultValue: 2147483648,
  ); // 2 GiB
  static const httpLogs = bool.fromEnvironment('HTTP_LOGS');

  /// [apiBaseUrl], or the origin of [page] (the app's own URL) when unset.
  static String resolveApiBaseUrl(Uri page) {
    final url = apiBaseUrl.trim();
    if (url.isNotEmpty) {
      return url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    }
    return page.origin;
  }
}
