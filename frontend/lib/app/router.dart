import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../cubits/session/session_cubit.dart';
import '../cubits/session/session_state.dart';
import '../pages/auth/confirm_signup_page.dart';
import '../pages/auth/forgot_password_page.dart';
import '../pages/auth/login_page.dart';
import '../pages/auth/reset_password_page.dart';
import '../pages/auth/sign_up_page.dart';
import '../pages/channel_page.dart';
import '../pages/history_page.dart';
import '../pages/home_page.dart';
import '../pages/not_found_page.dart';
import '../pages/search_page.dart';
import '../pages/shell/app_shell.dart';
import '../pages/upload_page.dart';
import '../pages/watch_page.dart';
import '../pages/your_videos_page.dart';
import 'routes.dart';

/// URL routing. Browse pages sit inside [AppShell] (masthead + sidebar);
/// the auth pages stand alone. Signing in or out re-runs [redirect].
GoRouter buildRouter(SessionCubit session, {String initialLocation = '/'}) {
  return GoRouter(
    initialLocation: initialLocation,
    refreshListenable: _SessionListenable(session),
    redirect: (context, state) => redirect(session.state, state.uri),
    errorPageBuilder: (context, state) =>
        const NoTransitionPage(child: AppShell(child: NotFoundPage())),
    routes: [
      ShellRoute(
        pageBuilder: (context, state, child) =>
            NoTransitionPage(child: AppShell(child: child)),
        routes: [
          _page(Routes.home, (s) => const HomePage()),
          _page(
            Routes.results,
            (s) => SearchPage(
              key: ValueKey(s.uri.queryParameters['search_query']),
              query: s.uri.queryParameters['search_query'] ?? '',
            ),
          ),
          _page(Routes.watchPath, (s) {
            final id = s.uri.queryParameters['v'];
            return id == null || id.isEmpty
                ? const NotFoundPage()
                : WatchPage(key: ValueKey(id), videoId: id);
          }),
          _page(
            '/channel/:id',
            (s) => ChannelPage(
              key: ValueKey(s.pathParameters['id']),
              userId: s.pathParameters['id']!,
            ),
          ),
          _page(
            '/channel/:id/videos',
            (s) => ChannelPage(
              key: ValueKey(s.pathParameters['id']),
              userId: s.pathParameters['id']!,
              tab: ChannelTab.videos,
            ),
          ),
          _page(Routes.myVideos, (s) => const YourVideosPage()),
          _page(Routes.upload, (s) => const UploadPage()),
          _page(Routes.history, (s) => const HistoryPage()),
        ],
      ),
      _page(
        Routes.signIn,
        (s) => LoginPage.provided(
          email: s.uri.queryParameters['email'],
          next: s.uri.queryParameters['next'],
        ),
      ),
      _page(
        Routes.signUp,
        (s) => SignUpPage.provided(next: s.uri.queryParameters['next']),
      ),
      _page(
        Routes.verify,
        (s) => ConfirmSignUpPage.provided(
          email: s.uri.queryParameters['email'] ?? '',
          freshCode: s.uri.queryParameters['sent'] == '1',
          sendCodeOnOpen: s.uri.queryParameters['resend'] == '1',
          next: s.uri.queryParameters['next'],
        ),
      ),
      _page(
        Routes.forgotPassword,
        (s) =>
            ForgotPasswordPage.provided(email: s.uri.queryParameters['email']),
      ),
      _page(
        Routes.resetPassword,
        (s) => ResetPasswordPage.provided(
          email: s.uri.queryParameters['email'] ?? '',
        ),
      ),
    ],
  );
}

GoRoute _page(String path, Widget Function(GoRouterState state) build) =>
    GoRoute(
      path: path,
      pageBuilder: (context, state) =>
          NoTransitionPage(key: state.pageKey, child: build(state)),
    );

/// Sign-in gating. Pages that need a session send signed-out visitors to
/// Sign in (and back afterwards); Sign in and Sign up send signed-in users
/// on. While the session is still being restored nothing moves: those pages
/// show a spinner until it settles.
String? redirect(SessionState session, Uri uri) {
  final path = uri.path;
  if (session is SessionUnauthenticated && Routes.signedInOnly.contains(path)) {
    return Routes.signInPage(next: uri.toString());
  }
  if (session is SessionAuthenticated && Routes.signedOutOnly.contains(path)) {
    return Routes.afterSignIn(uri.queryParameters['next']);
  }
  return null;
}

/// Notifies when the session changes kind (signed in, signed out, ...),
/// which is all [redirect] depends on.
class _SessionListenable extends ChangeNotifier {
  _SessionListenable(SessionCubit session) {
    _sub = session.stream
        .map((s) => s.runtimeType)
        .distinct()
        .listen((_) => notifyListeners());
  }

  late final StreamSubscription<Type> _sub;

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}
