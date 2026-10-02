class AppConfig {
  static const apiBaseUrl = String.fromEnvironment('API_BASE_URL');
  static const maxUploadBytes = int.fromEnvironment(
    'MAX_UPLOAD_BYTES',
    defaultValue: 2147483648,
  ); // 2 GiB
  static const httpLogs = bool.fromEnvironment('HTTP_LOGS');
}
