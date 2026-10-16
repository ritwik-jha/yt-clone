import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../core/api_client.dart';
import '../core/theme.dart';
import '../cubits/session/session_cubit.dart';
import '../cubits/upload_video/upload_video_cubit.dart';
import '../platform/browser.dart';
import '../platform/video_player.dart';
import '../services/auth_service.dart';
import '../services/upload_video_service.dart';
import '../services/video_service.dart';
import 'router.dart';

/// Makes a fresh [PlayerController] per watch page. Tests swap it.
class PlayerFactory {
  const PlayerFactory([this._create = createPlayerController]);
  final PlayerController Function() _create;
  PlayerController create() => _create();
}

class YtpApp extends StatefulWidget {
  const YtpApp({
    super.key,
    required this.apiBaseUrl,
    this.browser,
    this.players = const PlayerFactory(),
    this.initialLocation = '/',
    this.auth,
    this.videos,
    this.uploads,
  });

  final String apiBaseUrl;
  final Browser? browser;
  final PlayerFactory players;
  final String initialLocation;

  /// Test doubles; built from [apiBaseUrl] when null.
  final AuthService? auth;
  final VideoService? videos;
  final UploadVideoService? uploads;

  @override
  State<YtpApp> createState() => _YtpAppState();
}

class _YtpAppState extends State<YtpApp> {
  late final Browser _browser = widget.browser ?? createBrowser();
  late final ApiClient _client = ApiClient(
    baseUrl: widget.apiBaseUrl,
    onSessionExpired: () => _session.expired(),
  );
  late final AuthService _auth =
      widget.auth ?? AuthService(api: _client.api, bare: _client.bare);
  late final VideoService _videos = widget.videos ?? VideoService(_client.api);
  late final UploadVideoService _uploads =
      widget.uploads ?? UploadVideoService(api: _client.api, browser: _browser);
  late final SessionCubit _session = SessionCubit(auth: _auth);
  late final UploadVideoCubit _upload = UploadVideoCubit(
    _uploads,
    browser: _browser,
  );
  late final GoRouter _router = buildRouter(
    _session,
    initialLocation: widget.initialLocation,
  );

  @override
  void initState() {
    super.initState();
    _session.restore();
  }

  @override
  void dispose() {
    _router.dispose();
    _upload.close();
    _session.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MultiRepositoryProvider(
    providers: [
      RepositoryProvider.value(value: _browser),
      RepositoryProvider.value(value: widget.players),
      RepositoryProvider.value(value: _auth),
      RepositoryProvider.value(value: _videos),
      RepositoryProvider.value(value: _uploads),
    ],
    child: MultiBlocProvider(
      providers: [
        BlocProvider.value(value: _session),
        BlocProvider.value(value: _upload),
      ],
      child: MaterialApp.router(
        title: 'Video Stream',
        debugShowCheckedModeBanner: false,
        theme: buildDarkTheme(),
        darkTheme: buildDarkTheme(),
        themeMode: ThemeMode.dark,
        routerConfig: _router,
      ),
    ),
  );
}
