import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/api_exception.dart';
import '../../models/user_profile.dart';
import '../../services/auth_service.dart';
import 'session_state.dart';

/// Who is signed in, at the app root (plan §5.5). Browsing works signed out;
/// only uploading and Your videos need a session.
///
/// The session is the browser's HttpOnly cookies, so [restore] asks
/// `/auth/me` whether there is one. While signed in, the access cookie is
/// renewed every [refreshEvery], before it (and its 1-hour Cognito token)
/// expires: endpoints with optional auth would otherwise answer an expired
/// session as anonymous, hiding the owner's private videos.
class SessionCubit extends Cubit<SessionState> {
  SessionCubit({
    required this._auth,
    this.refreshEvery = const Duration(minutes: 50),
    this.beforeLogout,
  }) : super(const SessionUnknown());

  final AuthService _auth;
  final Duration refreshEvery;

  /// Runs before an explicit sign-out, while the cookies still work (watch
  /// history sends what is waiting, then forgets it). Its errors don't stop
  /// the sign-out.
  final Future<void> Function()? beforeLogout;
  Timer? _timer;

  UserProfile? get user => switch (state) {
    SessionAuthenticated(:final user) => user,
    _ => null,
  };

  Future<void> restore() async {
    emit(const SessionUnknown());
    try {
      final me = await _auth.me();
      _authenticated(me);
    } on ApiException catch (e) {
      if (e.kind == ApiErrorKind.unauthorized) {
        _signedOut(const SessionUnauthenticated());
      } else {
        emit(
          SessionUnavailable(
            e.isNetwork
                ? "Can't reach the server"
                : 'Service temporarily unavailable',
          ),
        );
      }
    }
  }

  void signedIn(UserProfile user) => _authenticated(user);

  /// Called by the auth interceptor when a refresh fails with 401.
  void expired() {
    // Only a live session can expire. During restore() (a visit with no
    // cookie) the 401 is handled there, without the "expired" message.
    if (state is! SessionAuthenticated) return;
    _signedOut(
      const SessionUnauthenticated(message: 'Session expired, sign in again'),
    );
  }

  Future<void> logout() async {
    _timer?.cancel();
    try {
      await beforeLogout?.call();
    } on Object {
      // Never keep someone signed in because a flush failed.
    }
    await _auth.logout();
    _signedOut(const SessionUnauthenticated());
  }

  void _authenticated(UserProfile user) {
    _timer?.cancel();
    _timer = Timer.periodic(refreshEvery, (_) => _refresh());
    emit(SessionAuthenticated(user));
  }

  void _signedOut(SessionUnauthenticated state) {
    _timer?.cancel();
    _timer = null;
    emit(state);
  }

  Future<void> _refresh() async {
    try {
      await _auth.refresh();
    } on ApiException catch (e) {
      // A network blip keeps the session; the next tick or a 401 retries.
      if (e.kind == ApiErrorKind.unauthorized) expired();
    }
  }

  @override
  Future<void> close() {
    _timer?.cancel();
    return super.close();
  }
}
