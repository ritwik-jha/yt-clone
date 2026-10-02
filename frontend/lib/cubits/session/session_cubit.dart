import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api_exception.dart';
import '../../core/token_store.dart';
import '../../models/user_profile.dart';
import '../../services/auth_service.dart';
import 'session_state.dart';

const installedFlag = 'installed';
const hasSignedInBeforeFlag = 'has_signed_in_before';

/// Owns the signed-in state at the app root (plan §5.5).
class SessionCubit extends Cubit<SessionState> {
  SessionCubit({
    required this._auth,
    required this._tokens,
    required this._prefs,
  }) : super(const SessionUnknown());

  final AuthService _auth;
  final TokenStore _tokens;
  final SharedPreferences _prefs;

  bool get hasSignedInBefore => _prefs.getBool(hasSignedInBeforeFlag) ?? false;

  UserProfile? get user => switch (state) {
    SessionAuthenticated(:final user) => user,
    _ => null,
  };

  Future<void> restore() async {
    emit(const SessionUnknown());

    // iOS Keychain items outlive an uninstall; shared_preferences doesn't.
    if (!(_prefs.getBool(installedFlag) ?? false)) {
      await _tokens.clear();
      await _prefs.setBool(installedFlag, true);
    }

    if (await _tokens.refreshToken() == null) {
      await _tokens.clear();
      emit(const SessionUnauthenticated());
      return;
    }

    try {
      final me = await _auth.me();
      await _prefs.setBool(hasSignedInBeforeFlag, true);
      emit(SessionAuthenticated(me));
    } on ApiException catch (e) {
      if (e.kind == ApiErrorKind.unauthorized) {
        await _tokens.clear();
        emit(const SessionUnauthenticated());
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

  Future<void> signedIn(UserProfile user) async {
    await _prefs.setBool(hasSignedInBeforeFlag, true);
    emit(SessionAuthenticated(user));
  }

  /// Called by the auth interceptor when a refresh fails with 401.
  void expired() {
    if (state is SessionUnauthenticated) return;
    emit(
      const SessionUnauthenticated(message: 'Session expired, sign in again'),
    );
  }

  Future<void> logout() async {
    await _auth.logout();
    emit(const SessionUnauthenticated());
  }
}
