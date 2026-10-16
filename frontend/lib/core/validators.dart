/// Client-side mirrors of `backend/app/schemas.py` (plan §3, §6).
class Validators {
  static String? name(String? v) {
    final s = (v ?? '').trim();
    if (s.length < 2) return 'Name must be at least 2 characters';
    if (s.length > 50) return 'Name must be at most 50 characters';
    return null;
  }

  static final _email = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

  static String? email(String? v) {
    final s = (v ?? '').trim();
    if (s.isEmpty) return 'Enter your email';
    if (s.length > 255 || !_email.hasMatch(s)) return 'Enter a valid email';
    return null;
  }

  /// First failing rule, or null.
  static String? newPassword(String? v) {
    final s = v ?? '';
    if (s.length < 8) return 'Password must be at least 8 characters';
    if (s.length > 256) return 'Password must be at most 256 characters';
    if (!RegExp('[A-Z]').hasMatch(s)) {
      return 'Password needs an uppercase letter';
    }
    if (!RegExp('[a-z]').hasMatch(s)) {
      return 'Password needs a lowercase letter';
    }
    if (!RegExp(r'\d').hasMatch(s)) return 'Password needs a number';
    if (!RegExp(r'[^A-Za-z0-9]').hasMatch(s)) {
      return 'Password needs a special character';
    }
    return null;
  }

  static String? loginPassword(String? v) =>
      (v ?? '').isEmpty ? 'Enter your password' : null;

  static String? otp(String? v) =>
      RegExp(r'^\d{6}$').hasMatch(v ?? '') ? null : 'Enter the 6-digit code';

  static String? videoTitle(String? v) {
    final s = (v ?? '').trim();
    if (s.isEmpty) return 'Enter a title';
    if (s.length > 100) return 'Title must be at most 100 characters';
    return null;
  }

  static const descriptionMax = 1000;

  static String? description(String? v) => (v ?? '').length > descriptionMax
      ? 'Description must be at most $descriptionMax characters'
      : null;
}
