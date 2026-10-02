import 'package:equatable/equatable.dart';

import '../../models/user_profile.dart';

sealed class AuthState extends Equatable {
  const AuthState();
  @override
  List<Object?> get props => [];
}

class AuthInitial extends AuthState {
  const AuthInitial();
}

class AuthLoading extends AuthState {
  const AuthLoading();
}

class AuthSignUpSuccess extends AuthState {
  const AuthSignUpSuccess(this.email, {this.codeSent = true});
  final String email;

  /// False when the account was created but the email didn't go out.
  final bool codeSent;
  @override
  List<Object?> get props => [email, codeSent];
}

class AuthConfirmSignUpSuccess extends AuthState {
  const AuthConfirmSignUpSuccess(this.email);
  final String email;
  @override
  List<Object?> get props => [email];
}

class AuthNeedsVerification extends AuthState {
  const AuthNeedsVerification(this.email);
  final String email;
  @override
  List<Object?> get props => [email];
}

class AuthNeedsPasswordReset extends AuthState {
  const AuthNeedsPasswordReset(this.email);
  final String email;
  @override
  List<Object?> get props => [email];
}

class AuthCodeSent extends AuthState {
  const AuthCodeSent(this.message);
  final String message;
  @override
  List<Object?> get props => [message];
}

class AuthResetCodeSent extends AuthState {
  const AuthResetCodeSent(this.email, this.message);
  final String email;
  final String message;
  @override
  List<Object?> get props => [email, message];
}

class AuthPasswordResetSuccess extends AuthState {
  const AuthPasswordResetSuccess(this.email, this.message);
  final String email;
  final String message;
  @override
  List<Object?> get props => [email, message];
}

class AuthLoginSuccess extends AuthState {
  const AuthLoginSuccess(this.user);
  final UserProfile user;
  @override
  List<Object?> get props => [user];
}

class AuthError extends AuthState {
  const AuthError(
    this.message, {
    this.code,
    this.fieldErrors = const {},
    this.nonce = 0,
  });
  final String message;
  final String? code;
  final Map<String, String> fieldErrors;

  /// Makes two identical consecutive errors distinct states.
  final int nonce;
  @override
  List<Object?> get props => [message, code, fieldErrors, nonce];
}
