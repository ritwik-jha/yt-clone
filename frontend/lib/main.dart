import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/api_client.dart';
import 'core/config.dart';
import 'core/theme.dart';
import 'core/token_store.dart';
import 'cubits/session/session_cubit.dart';
import 'cubits/session/session_state.dart';
import 'pages/auth/login_page.dart';
import 'pages/auth/sign_up_page.dart';
import 'pages/home_page.dart';
import 'pages/splash_page.dart';
import 'services/auth_service.dart';
import 'services/upload_video_service.dart';
import 'services/video_service.dart';

final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (AppConfig.apiBaseUrl.isEmpty) {
    throw StateError(
      'API_BASE_URL is not set. Run with --dart-define-from-file=env/dev.json',
    );
  }
  final prefs = await SharedPreferences.getInstance();
  runApp(YtpApp(prefs: prefs));
}

class YtpApp extends StatefulWidget {
  const YtpApp({super.key, required this.prefs, this.tokens, this.baseUrl});

  final SharedPreferences prefs;
  final TokenStore? tokens;
  final String? baseUrl;

  @override
  State<YtpApp> createState() => _YtpAppState();
}

class _YtpAppState extends State<YtpApp> {
  late final TokenStore _tokens =
      widget.tokens ?? TokenStore(const FlutterSecureKv());
  late final ApiClient _client = ApiClient(
    tokens: _tokens,
    baseUrl: widget.baseUrl,
    onSessionExpired: () => _session.expired(),
  );
  late final AuthService _auth = AuthService(
    api: _client.api,
    bare: _client.bare,
    tokens: _tokens,
  );
  late final VideoService _videos = VideoService(_client.api);
  late final UploadVideoService _uploads = UploadVideoService(
    api: _client.api,
    s3: _client.s3,
  );
  late final SessionCubit _session = SessionCubit(
    auth: _auth,
    tokens: _tokens,
    prefs: widget.prefs,
  );

  @override
  void initState() {
    super.initState();
    _session.restore();
  }

  @override
  void dispose() {
    _session.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MultiRepositoryProvider(
    providers: [
      RepositoryProvider.value(value: _auth),
      RepositoryProvider.value(value: _videos),
      RepositoryProvider.value(value: _uploads),
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
        home: const _Root(),
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
