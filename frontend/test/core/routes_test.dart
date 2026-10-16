import 'package:flutter_test/flutter_test.dart';
import 'package:ytp_app/app/router.dart';
import 'package:ytp_app/app/routes.dart';
import 'package:ytp_app/core/config.dart';
import 'package:ytp_app/cubits/session/session_state.dart';
import 'package:ytp_app/models/user_profile.dart';

void main() {
  const user = UserProfile(id: 'u', name: 'U', email: 'u@x.co');

  test('URLs', () {
    expect(Routes.watch('abc'), '/watch?v=abc');
    expect(
      Routes.search(' cats  & dogs '),
      '/results?search_query=cats++%26+dogs',
    );
    expect(Routes.channel('u1'), '/channel/u1');
    expect(Routes.channel('u1', videos: true), '/channel/u1/videos');
    expect(Routes.signInPage(), '/signin');
    expect(
      Routes.signInPage(next: '/watch?v=1', email: 'a@b.co'),
      '/signin?next=%2Fwatch%3Fv%3D1&email=a%40b.co',
    );
    expect(
      Routes.verifyPage('a@b.co', sent: true),
      '/verify?email=a%40b.co&sent=1',
    );
  });

  test('afterSignIn only follows paths inside the app', () {
    expect(Routes.afterSignIn('/upload'), '/upload');
    expect(Routes.afterSignIn(null), '/');
    expect(Routes.afterSignIn('https://evil.example'), '/');
    expect(Routes.afterSignIn('//evil.example/x'), '/');
  });

  test('redirect gates the signed-in pages', () {
    Uri u(String s) => Uri.parse(s);
    const out = SessionUnauthenticated();
    const known = SessionAuthenticated(user);
    expect(redirect(out, u('/upload')), '/signin?next=%2Fupload');
    expect(redirect(out, u('/my-videos')), '/signin?next=%2Fmy-videos');
    expect(redirect(out, u('/')), isNull);
    expect(redirect(out, u('/watch?v=1')), isNull);
    expect(redirect(known, u('/upload')), isNull);
    expect(redirect(known, u('/signin?next=%2Fupload')), '/upload');
    expect(redirect(known, u('/signup')), '/');
    // Still restoring: nobody is moved yet.
    expect(redirect(const SessionUnknown(), u('/upload')), isNull);
    expect(redirect(const SessionUnknown(), u('/signin')), isNull);
  });

  test('the API defaults to the page origin', () {
    expect(
      AppConfig.resolveApiBaseUrl(
        Uri.parse('https://videos.example.com/watch?v=1'),
      ),
      AppConfig.apiBaseUrl.isEmpty
          ? 'https://videos.example.com'
          : AppConfig.apiBaseUrl,
    );
  });
}
