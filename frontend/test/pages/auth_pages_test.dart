import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ytp_app/core/api_exception.dart';

import '../cubits/helpers.dart';
import 'harness.dart';

void main() {
  setUpAll(Harness.registerFallbacks);

  late Harness h;
  late MockAuthService auth;
  setUp(() {
    h = Harness();
    auth = h.auth;
  });

  testWidgets('sign up: weak password is rejected on the client', (
    tester,
  ) async {
    await h.pump(tester, location: '/signup');
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
    await h.pump(tester, location: '/signup');
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
    await h.pump(tester, location: '/signup');
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
    await h.pump(tester, location: '/verify?email=ada%40x.co&sent=1');
    expect(find.widgetWithText(TextFormField, 'ada@x.co'), findsOneWidget);
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

  testWidgets('sign up success goes to Confirm with the cooldown running', (
    tester,
  ) async {
    when(() => auth.signUp(any(), any(), any())).thenAnswer((_) async {});
    await h.pump(tester, location: '/signup?next=%2Fupload');
    await tester.enterText(find.widgetWithText(TextFormField, 'Name'), 'Ada');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email'),
      'Ada@X.co',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'Passw0rd!',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Sign Up'));
    await tester.pump();
    await tester.pump();
    expect(location(tester), '/verify?email=ada%40x.co&sent=1&next=%2Fupload');
    expect(find.text('Resend in 60 s'), findsOneWidget);
    await tester.pump(const Duration(seconds: 61));
  });

  testWidgets('confirm success goes to Sign in with the email filled', (
    tester,
  ) async {
    when(() => auth.verifyOtp(any(), any())).thenAnswer((_) async {});
    await h.pump(tester, location: '/verify?email=ada%40x.co');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Verification code'),
      '123456',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.pumpAndSettle();
    verify(() => auth.verifyOtp('ada@x.co', '123456')).called(1);
    expect(location(tester), '/signin?email=ada%40x.co');
    expect(find.widgetWithText(TextFormField, 'ada@x.co'), findsOneWidget);
  });

  testWidgets('sign in: wrong password shows the error and clears it', (
    tester,
  ) async {
    when(() => auth.login(any(), any())).thenThrow(
      ApiException.fromResponse(400, <String, dynamic>{
        'code': 'incorrect_credentials',
        'detail': 'Incorrect email or password',
      }),
    );
    await h.pump(tester, location: '/signin');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email'),
      'a@x.co',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'nope',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Sign In'));
    await tester.pumpAndSettle();
    expect(find.text('Incorrect email or password'), findsOneWidget);
    expect(location(tester), '/signin');
  });

  testWidgets('sign in: an unconfirmed account goes to Confirm and resends', (
    tester,
  ) async {
    when(() => auth.login(any(), any())).thenThrow(
      ApiException.fromResponse(400, <String, dynamic>{
        'code': 'user_not_confirmed',
        'detail': 'Account not verified',
      }),
    );
    when(() => auth.resendOtp(any())).thenAnswer((_) async => 'Code sent');
    await h.pump(tester, location: '/signin');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email'),
      'c@x.co',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'Pw',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Sign In'));
    await tester.pumpAndSettle();
    expect(location(tester), '/verify?email=c%40x.co&resend=1');
    verify(() => auth.resendOtp('c@x.co')).called(1);
    await tester.pump(const Duration(seconds: 61));
  });

  testWidgets('forgot -> reset -> sign in', (tester) async {
    when(() => auth.forgotPassword(any())).thenAnswer((_) async => 'Code sent');
    when(() => auth.resetPassword(any(), any(), any()))
        .thenAnswer((_) async => 'Password reset');
    await h.pump(tester, location: '/forgot-password?email=a%40x.co');
    await tester.tap(find.widgetWithText(FilledButton, 'Send code'));
    await tester.pumpAndSettle();
    expect(location(tester), '/reset-password?email=a%40x.co');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Verification code'),
      '654321',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'New password'),
      'N3w-Passw0rd',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Reset password'));
    await tester.pumpAndSettle();
    verify(() => auth.resetPassword('a@x.co', '654321', 'N3w-Passw0rd'))
        .called(1);
    expect(location(tester), '/signin?email=a%40x.co');
    await tester.pump(const Duration(seconds: 61));
  });
}
