import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../core/api_exception.dart';
import '../core/token_store.dart';
import '../models/user_profile.dart';

class AuthService {
  AuthService({required this._api, required this._bare, required this._tokens});

  final Dio _api;
  final Dio _bare;
  final TokenStore _tokens;

  Future<String> _post(String path, Map<String, dynamic> body) =>
      guardApi(() async {
        final res = await _api.post<Map<String, dynamic>>(path, data: body);
        return (res.data?['message'] as String?) ?? '';
      });

  Future<void> signUp(String name, String email, String password) =>
      _post('/auth/signup', {
        'name': name.trim(),
        'email': email.trim().toLowerCase(),
        'password': password,
      });

  Future<void> verifyOtp(String email, String otp) => _post(
    '/auth/verify-otp',
    {'email': email.trim().toLowerCase(), 'otp': otp},
  );

  /// Returns the server's message.
  Future<String> resendOtp(String email) =>
      _post('/auth/resend-otp', {'email': email.trim().toLowerCase()});

  Future<String> forgotPassword(String email) =>
      _post('/auth/forgot-password', {'email': email.trim().toLowerCase()});

  Future<String> resetPassword(String email, String otp, String newPassword) =>
      _post('/auth/reset-password', {
        'email': email.trim().toLowerCase(),
        'otp': otp,
        'new_password': newPassword,
      });

  /// Logs in (CookieCapture stores the tokens) and loads the profile.
  Future<UserProfile> login(String email, String password) async {
    await _post('/auth/login', {
      'email': email.trim().toLowerCase(),
      'password': password,
    });
    if (!kIsWeb && await _tokens.accessToken() == null) {
      throw const ApiException(
        kind: ApiErrorKind.server,
        message: 'Sign-in failed. Please try again.',
      );
    }
    return me();
  }

  Future<UserProfile> me() => guardApi(() async {
    final res = await _api.get<Map<String, dynamic>>('/auth/me');
    return UserProfile.fromJson(res.data!);
  });

  /// Best effort: the local session is cleared whatever this returns.
  Future<void> logout() async {
    final refresh = await _tokens.refreshToken();
    try {
      await _bare.post<dynamic>(
        '/auth/logout',
        options: refresh == null
            ? null
            : Options(headers: {'Cookie': 'refresh_token=$refresh'}),
      );
    } on DioException {
      // ignored
    }
    await _tokens.clear();
  }
}
