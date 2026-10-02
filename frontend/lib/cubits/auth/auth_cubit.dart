import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/api_exception.dart';
import '../../services/auth_service.dart';
import '../session/session_cubit.dart';
import 'auth_state.dart';

/// Form actions for the auth pages. Created per page, so one screen's error
/// never shows up on another (plan §5.6).
class AuthCubit extends Cubit<AuthState> {
  AuthCubit(this._auth, this._session) : super(const AuthInitial());

  final AuthService _auth;
  final SessionCubit _session;
  int _errors = 0;

  AuthError _error(ApiException e) => AuthError(
    e.message,
    code: e.code,
    fieldErrors: e.fieldErrors,
    nonce: _errors++,
  );

  Future<void> signUpUser(String name, String email, String password) async {
    emit(const AuthLoading());
    try {
      await _auth.signUp(name, email, password);
      emit(AuthSignUpSuccess(email.trim().toLowerCase()));
    } on ApiException catch (e) {
      if (e.code == 'code_delivery_failed') {
        // The account exists; Resend on Confirm Sign Up covers it.
        emit(AuthSignUpSuccess(email.trim().toLowerCase(), codeSent: false));
      } else {
        emit(_error(e));
      }
    }
  }

  Future<void> confirmSignUpUser(String email, String otp) async {
    emit(const AuthLoading());
    try {
      await _auth.verifyOtp(email, otp);
      emit(AuthConfirmSignUpSuccess(email.trim().toLowerCase()));
    } on ApiException catch (e) {
      emit(_error(e));
    }
  }

  Future<void> resendCode(String email) async {
    emit(const AuthLoading());
    try {
      emit(AuthCodeSent(await _auth.resendOtp(email)));
    } on ApiException catch (e) {
      emit(_error(e));
    }
  }

  Future<void> forgotPassword(String email) async {
    emit(const AuthLoading());
    try {
      final msg = await _auth.forgotPassword(email);
      emit(AuthResetCodeSent(email.trim().toLowerCase(), msg));
    } on ApiException catch (e) {
      emit(_error(e));
    }
  }

  /// Re-sends the reset code from the Reset Password page.
  Future<void> resendResetCode(String email) async {
    emit(const AuthLoading());
    try {
      emit(AuthCodeSent(await _auth.forgotPassword(email)));
    } on ApiException catch (e) {
      emit(_error(e));
    }
  }

  Future<void> resetPassword(
    String email,
    String otp,
    String newPassword,
  ) async {
    emit(const AuthLoading());
    try {
      final msg = await _auth.resetPassword(email, otp, newPassword);
      emit(AuthPasswordResetSuccess(email.trim().toLowerCase(), msg));
    } on ApiException catch (e) {
      emit(_error(e));
    }
  }

  Future<void> loginUser(String email, String password) async {
    emit(const AuthLoading());
    try {
      final user = await _auth.login(email, password);
      emit(AuthLoginSuccess(user));
      await _session.signedIn(user);
    } on ApiException catch (e) {
      final normalized = email.trim().toLowerCase();
      switch (e.code) {
        case 'user_not_confirmed':
          emit(AuthNeedsVerification(normalized));
        case 'password_reset_required':
          emit(AuthNeedsPasswordReset(normalized));
        default:
          emit(_error(e));
      }
    }
  }
}
