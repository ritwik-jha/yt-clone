/// The app's URLs, YouTube-shaped so links read naturally.
class Routes {
  static const home = '/';
  static const results = '/results';
  static const watchPath = '/watch';
  static const myVideos = '/my-videos';
  static const upload = '/upload';
  static const signIn = '/signin';
  static const signUp = '/signup';
  static const verify = '/verify';
  static const forgotPassword = '/forgot-password';
  static const resetPassword = '/reset-password';

  /// Pages that need a session; signed-out visitors go to Sign in first.
  static const signedInOnly = {myVideos, upload};

  /// Pages a signed-in user has no reason to see.
  static const signedOutOnly = {signIn, signUp};

  static String watch(String id) => _with(watchPath, {'v': id});

  static String search(String query) =>
      _with(results, {'search_query': query.trim()});

  static String channel(String userId, {bool videos = false}) =>
      '/channel/$userId${videos ? '/videos' : ''}';

  static String signInPage({String? next, String? email}) =>
      _with(signIn, {'next': next, 'email': email});

  static String signUpPage({String? next}) => _with(signUp, {'next': next});

  /// [sent]: a code was just emailed (start the resend cooldown).
  /// [resend]: send a fresh code on open (an unconfirmed account signing in).
  static String verifyPage(
    String email, {
    bool sent = false,
    bool resend = false,
    String? next,
  }) => _with(verify, {
    'email': email,
    if (sent) 'sent': '1',
    if (resend) 'resend': '1',
    'next': next,
  });

  static String forgotPasswordPage({String? email}) =>
      _with(forgotPassword, {'email': email});

  static String resetPasswordPage(String email) =>
      _with(resetPassword, {'email': email});

  /// Where to land after signing in: [next] if it is one of ours.
  static String afterSignIn(String? next) =>
      next != null && next.startsWith('/') && !next.startsWith('//')
      ? next
      : home;

  static String _with(String path, Map<String, String?> query) {
    final params = {
      for (final e in query.entries)
        if (e.value != null && e.value!.isNotEmpty) e.key: e.value!,
    };
    return Uri(
      path: path,
      queryParameters: params.isEmpty ? null : params,
    ).toString();
  }
}
