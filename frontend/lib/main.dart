import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'app/app.dart';
import 'core/config.dart';
import 'core/crash_reporter.dart';

export 'app/app.dart';

void main() {
  // Real paths (/watch?v=...) rather than #/ fragments. The host must answer
  // every unknown path with index.html (see SETUP.md).
  usePathUrlStrategy();
  installCrashReporting();
  runApp(YtpApp(apiBaseUrl: AppConfig.resolveApiBaseUrl(Uri.base)));
}
