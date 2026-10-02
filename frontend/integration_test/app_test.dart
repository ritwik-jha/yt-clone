// End-to-end smoke test against a deployed (or local) backend.
//
//   flutter test integration_test \
//     --dart-define-from-file=env/dev.json \
//     --dart-define=TEST_EMAIL=you@example.com \
//     --dart-define=TEST_PASSWORD='Passw0rd!'
//
// The account must already exist and be confirmed
// (`aws cognito-idp admin-confirm-sign-up ...`, see SETUP.md). It takes
// minutes against a real stack, so run it on demand, on a device or emulator.
//
// The native photo/video pickers can't be driven from Flutter, so uploading
// and the "watch it reach Ready" flow stay in the manual checklist.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ytp_app/core/server_settings.dart';
import 'package:ytp_app/core/token_store.dart';
import 'package:ytp_app/main.dart';
import 'package:ytp_app/widgets/video_card.dart';

const _email = String.fromEnvironment('TEST_EMAIL');
const _password = String.fromEnvironment('TEST_PASSWORD');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sign in, browse the feed, play a video, log out', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'installed': true});
    final prefs = await SharedPreferences.getInstance();
    final tokens = TokenStore(const FlutterSecureKv());
    await tokens.clear();
    final settings = ServerSettings(prefs: prefs, tokens: tokens);
    expect(settings.url, isNotNull, reason: 'pass API_BASE_URL');

    await tester.pumpWidget(
      YtpApp(prefs: prefs, tokens: tokens, settings: settings),
    );
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // Sign in (the app starts on Sign Up for a fresh install).
    if (find.text('Sign In').evaluate().isEmpty) {
      await tester.tap(find.widgetWithText(TextButton, 'Sign In'));
      await tester.pumpAndSettle();
    }
    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), _email);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      _password,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Sign In'));
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // Home feed loaded (or is legitimately empty).
    expect(find.text('Video Stream'), findsWidgets);
    final cards = find.byType(VideoCard);
    if (cards.evaluate().isNotEmpty) {
      await tester.tap(cards.first);
      await tester.pumpAndSettle(const Duration(seconds: 5));
      await tester.pageBack();
      await tester.pumpAndSettle();
    }

    // Log out and land back on an auth screen.
    await tester.tap(find.byTooltip('Account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Log out'));
    await tester.pumpAndSettle(const Duration(seconds: 3));
    expect(find.text('Sign In'), findsWidgets);
  }, skip: _email.isEmpty || _password.isEmpty);
}
