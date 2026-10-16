import 'package:dio/dio.dart';

import '../core/api_exception.dart';
import '../models/user_profile.dart';

/// Auth calls. The session is a pair of HttpOnly cookies the browser keeps;
/// this class never sees a token.
class AuthService {
  AuthService({required this._api, required this._bare});

  final Dio _api;
  final Dio _bare;

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

  /// Logs in (the browser stores the cookies) and loads the profile.
  Future<UserProfile> login(String email, String password) async {
    await _post('/auth/login', {
      'email': email.trim().toLowerCase(),
      'password': password,
    });
    return me();
  }

  Future<UserProfile> me() => guardApi(() async {
    final res = await _api.get<Map<String, dynamic>>('/auth/me');
    return UserProfile.fromJson(res.data!);
  });

  /// Renews the access cookie before it expires. Throws [ApiException];
  /// `unauthorized` means the session is over.
  Future<void> refresh() =>
      guardApi(() => _bare.post<dynamic>('/auth/refresh'));

  /// Revokes the refresh token and clears the cookies. Best effort: the app
  /// signs out locally whatever this returns.
  Future<void> logout() async {
    try {
      await _bare.post<dynamic>('/auth/logout');
    } on DioException {
      // ignored
    }
  }
}
