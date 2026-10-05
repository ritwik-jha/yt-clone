import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/api_client.dart';
import 'core/crash_reporter.dart';
import 'core/server_settings.dart';
import 'core/theme.dart';
import 'core/token_store.dart';
import 'cubits/session/session_cubit.dart';
import 'cubits/session/session_state.dart';
import 'pages/auth/login_page.dart';
import 'pages/auth/sign_up_page.dart';
import 'pages/home_page.dart';
import 'pages/server_setup_page.dart';
import 'pages/splash_page.dart';
import 'services/auth_service.dart';
import 'services/upload_job_store.dart';
import 'services/upload_video_service.dart';
import 'services/video_service.dart';

final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  installCrashReporting();
  final prefs = await SharedPreferences.getInstance();
  final tokens = TokenStore(const FlutterSecureKv());
  final settings = ServerSettings(prefs: prefs, tokens: tokens);
  // Release builds have nowhere to ask for a URL, so fail fast.
  if (settings.url == null && !settings.canChange) {
    throw StateError(
      'API_BASE_URL is not set. Build with --dart-define-from-file=env/prod.json',
    );
  }
  runApp(YtpApp(prefs: prefs, tokens: tokens, settings: settings));
}

class YtpApp extends StatefulWidget {
  const YtpApp({
    super.key,
    required this.prefs,
    required this.tokens,
    required this.settings,
  });

  final SharedPreferences prefs;
  final TokenStore tokens;
  final ServerSettings settings;

  @override
  State<YtpApp> createState() => _YtpAppState();
}

class _YtpAppState extends State<YtpApp> {
  late final ApiClient _client = ApiClient(
    tokens: widget.tokens,
    baseUrl: widget.settings.url ?? '',
    onSessionExpired: () => _session.expired(),
  );
  late final AuthService _auth = AuthService(
    api: _client.api,
    bare: _client.bare,
    tokens: widget.tokens,
  );
  late final VideoService _videos = VideoService(_client.api);
  late final UploadVideoService _uploads = UploadVideoService(
    api: _client.api,
    s3: _client.s3,
  );
  final UploadJobStore _jobs = UploadJobStore();
  late final SessionCubit _session = SessionCubit(
    auth: _auth,
    tokens: widget.tokens,
    prefs: widget.prefs,
  );

  @override
  void initState() {
    super.initState();
    widget.settings.attach(_client);
    widget.settings.urlNotifier.addListener(_onServerChanged);
    if (widget.settings.url != null) _session.restore();
  }

  // A new server means a new identity pool: start over from the session check.
  void _onServerChanged() {
    if (widget.settings.url != null) _session.restore();
  }

  @override
  void dispose() {
    widget.settings.urlNotifier.removeListener(_onServerChanged);
    _session.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MultiRepositoryProvider(
    providers: [
      RepositoryProvider.value(value: widget.settings),
      RepositoryProvider.value(value: widget.tokens),
      RepositoryProvider.value(value: _auth),
      RepositoryProvider.value(value: _videos),
      RepositoryProvider.value(value: _uploads),
      RepositoryProvider.value(value: _jobs),
    ],
    child: BlocProvider.value(
      value: _session,
      child: MaterialApp(
        title: 'Video Stream',
        debugShowCheckedModeBanner: false,
        theme: buildDarkTheme(),
        darkTheme: buildDarkTheme(),
        themeMode: ThemeMode.dark,
        navigatorKey: navigatorKey,
        home: ListenableBuilder(
          listenable: widget.settings.urlNotifier,
          builder: (context, _) => widget.settings.url == null
              ? ServerSetupPage(settings: widget.settings)
              : const _Root(),
        ),
      ),
    ),
  );
}

class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) =>
      BlocConsumer<SessionCubit, SessionState>(
        listenWhen: (prev, next) => prev.runtimeType != next.runtimeType,
        // Pages pushed on top of the old root (the auth stack, or Upload when a
        // session expires) would otherwise stay visible over the new root.
        listener: (context, state) =>
            navigatorKey.currentState?.popUntil((r) => r.isFirst),
        builder: (context, state) => switch (state) {
          SessionUnknown() || SessionUnavailable() => const SplashPage(),
          SessionAuthenticated() => const HomePage(),
          SessionUnauthenticated() =>
            context.read<SessionCubit>().hasSignedInBefore
                ? LoginPage.provided(context)
                : SignUpPage.provided(context),
        },
      );
}
