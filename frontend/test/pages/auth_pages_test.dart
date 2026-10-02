import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ytp_app/core/api_exception.dart';
import 'package:ytp_app/core/theme.dart';
import 'package:ytp_app/core/token_store.dart';
import 'package:ytp_app/cubits/session/session_cubit.dart';
import 'package:ytp_app/pages/auth/confirm_signup_page.dart';
import 'package:ytp_app/pages/auth/sign_up_page.dart';
import 'package:ytp_app/services/auth_service.dart';

import '../cubits/helpers.dart';

Future<Widget> _app(
  MockAuthService auth,
  Widget Function(BuildContext) home,
) async {
  SharedPreferences.setMockInitialValues({});
  final session = SessionCubit(
    auth: auth,
    tokens: TokenStore(MemoryKv()),
    prefs: await SharedPreferences.getInstance(),
  );
  return RepositoryProvider<AuthService>.value(
    value: auth,
    child: BlocProvider.value(
      value: session,
      child: MaterialApp(
        theme: buildDarkTheme(),
        home: Builder(builder: home),
      ),
    ),
  );
}

void main() {
  late MockAuthService auth;
  setUp(() => auth = MockAuthService());

  testWidgets('sign up: weak password is rejected on the client', (
    tester,
  ) async {
    await tester.pumpWidget(await _app(auth, SignUpPage.provided));
    await tester.enterText(find.widgetWithText(TextFormField, 'Name'), 'Ada');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email'),
      'ada@x.co',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'weak',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Sign Up'));
    await tester.pump();
    expect(find.textContaining('at least 8 characters'), findsOneWidget);
    verifyNever(() => auth.signUp(any(), any(), any()));
  });

  testWidgets('sign up: server field error shows under the field', (
    tester,
  ) async {
    when(() => auth.signUp(any(), any(), any())).thenThrow(
      ApiException.fromResponse(400, <String, dynamic>{
        'code': 'validation_error',
        'detail': [
          {
            'loc': ['body', 'email'],
            'msg': 'Value error, email domain is not allowed',
          },
        ],
      }),
    );
    await tester.pumpWidget(await _app(auth, SignUpPage.provided));
    await tester.enterText(find.widgetWithText(TextFormField, 'Name'), 'Ada');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email'),
      'ada@x.co',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'Passw0rd!',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Sign Up'));
    await tester.pumpAndSettle();
    expect(find.text('email domain is not allowed'), findsOneWidget);
  });

  testWidgets('sign up: email_exists offers Sign in / Verify this email', (
    tester,
  ) async {
    when(() => auth.signUp(any(), any(), any())).thenThrow(
      ApiException.fromResponse(400, <String, dynamic>{
        'code': 'email_exists',
        'detail': 'An account with this email already exists',
      }),
    );
    await tester.pumpWidget(await _app(auth, SignUpPage.provided));
    await tester.enterText(find.widgetWithText(TextFormField, 'Name'), 'Ada');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email'),
      'ada@x.co',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'Passw0rd!',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Sign Up'));
    await tester.pumpAndSettle();
    expect(
      find.text('An account with this email already exists'),
      findsOneWidget,
    );
    expect(find.text('Verify this email'), findsOneWidget);
  });

  testWidgets('confirm: OTP must be 6 digits; resend cooldown counts down', (
    tester,
  ) async {
    await tester.pumpWidget(
      await _app(
        auth,
        (ctx) =>
            ConfirmSignUpPage.provided(ctx, email: 'ada@x.co', freshCode: true),
      ),
    );
    expect(find.text('Resend in 60 s'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Resend in 59 s'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Verification code'),
      '123',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.pump();
    expect(find.text('Enter the 6-digit code'), findsOneWidget);
    verifyNever(() => auth.verifyOtp(any(), any()));
    // Let the cooldown timer finish so the test ends cleanly.
    await tester.pump(const Duration(seconds: 61));
  });
}
