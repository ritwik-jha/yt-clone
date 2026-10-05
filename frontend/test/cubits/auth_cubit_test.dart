import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ytp_app/core/api_exception.dart';
import 'package:ytp_app/core/token_store.dart';
import 'package:ytp_app/cubits/auth/auth_cubit.dart';
import 'package:ytp_app/cubits/auth/auth_state.dart';
import 'package:ytp_app/cubits/session/session_cubit.dart';
import 'package:ytp_app/cubits/session/session_state.dart';
import 'package:ytp_app/models/user_profile.dart';

import 'helpers.dart';

ApiException _err(String code, {int status = 400}) => ApiException.fromResponse(
  status,
  <String, dynamic>{'code': code, 'detail': 'detail for $code'},
);

const _me = UserProfile(id: 'u1', name: 'Ada', email: 'a@b.co');

void main() {
  late MockAuthService auth;
  late SessionCubit session;
  late TokenStore tokens;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    auth = MockAuthService();
    tokens = TokenStore(MemoryKv());
    session = SessionCubit(
      auth: auth,
      tokens: tokens,
      prefs: await SharedPreferences.getInstance(),
    );
  });

  group('AuthCubit', () {
    blocTest<AuthCubit, AuthState>(
      'login success emits success and signs the session in',
      build: () {
        when(() => auth.login(any(), any())).thenAnswer((_) async => _me);
        return AuthCubit(auth, session);
      },
      act: (c) => c.loginUser('A@B.co', 'pw'),
      expect: () => [const AuthLoading(), const AuthLoginSuccess(_me)],
      verify: (_) => expect(session.state, const SessionAuthenticated(_me)),
    );

    blocTest<AuthCubit, AuthState>(
      'user_not_confirmed routes to verification',
      build: () {
        when(() => auth.login(any(), any()))
            .thenThrow(_err('user_not_confirmed'));
        return AuthCubit(auth, session);
      },
      act: (c) => c.loginUser(' A@B.co ', 'pw'),
      expect: () => [
        const AuthLoading(),
        const AuthNeedsVerification('a@b.co'),
      ],
    );

    blocTest<AuthCubit, AuthState>(
      'password_reset_required routes to forgot password',
      build: () {
        when(() => auth.login(any(), any()))
            .thenThrow(_err('password_reset_required'));
        return AuthCubit(auth, session);
      },
      act: (c) => c.loginUser('a@b.co', 'pw'),
      expect: () => [
        const AuthLoading(),
        const AuthNeedsPasswordReset('a@b.co'),
      ],
    );

    blocTest<AuthCubit, AuthState>(
      'incorrect_credentials is an AuthError with its code',
      build: () {
        when(() => auth.login(any(), any()))
            .thenThrow(_err('incorrect_credentials'));
        return AuthCubit(auth, session);
      },
      act: (c) => c.loginUser('a@b.co', 'pw'),
      expect: () => [
        const AuthLoading(),
        isA<AuthError>().having((e) => e.code, 'code', 'incorrect_credentials'),
      ],
    );

    blocTest<AuthCubit, AuthState>(
      'signup: code_delivery_failed still moves on, without a sent code',
      build: () {
        when(() => auth.signUp(any(), any(), any()))
            .thenThrow(_err('code_delivery_failed', status: 503));
        return AuthCubit(auth, session);
      },
      act: (c) => c.signUpUser('Ada', 'a@b.co', 'Passw0rd!'),
      expect: () => [
        const AuthLoading(),
        const AuthSignUpSuccess('a@b.co', codeSent: false),
      ],
    );

    blocTest<AuthCubit, AuthState>(
      'forgot + reset flow states',
      build: () {
        when(() => auth.forgotPassword(any())).thenAnswer((_) async => 'sent');
        when(() => auth.resetPassword(any(), any(), any()))
            .thenAnswer((_) async => 'done');
        return AuthCubit(auth, session);
      },
      act: (c) async {
        await c.forgotPassword('a@b.co');
        await c.resetPassword('a@b.co', '123456', 'Passw0rd!');
      },
      expect: () => [
        const AuthLoading(),
        const AuthResetCodeSent('a@b.co', 'sent'),
        const AuthLoading(),
        const AuthPasswordResetSuccess('a@b.co', 'done'),
      ],
    );

    blocTest<AuthCubit, AuthState>(
      'resend emits AuthCodeSent with the server message',
      build: () {
        when(() => auth.resendOtp(any())).thenAnswer((_) async => 'Code sent');
        return AuthCubit(auth, session);
      },
      act: (c) => c.resendCode('a@b.co'),
      expect: () => [const AuthLoading(), const AuthCodeSent('Code sent')],
    );
  });

  group('SessionCubit.restore', () {
    test('no refresh token -> unauthenticated, no network call', () async {
      await session.restore();
      expect(session.state, const SessionUnauthenticated());
      verifyNever(() => auth.me());
    });

    test('valid session -> authenticated', () async {
      SharedPreferences.setMockInitialValues({installedFlag: true});
      session = SessionCubit(
        auth: auth,
        tokens: tokens,
        prefs: await SharedPreferences.getInstance(),
      );
      await tokens.save(refreshTokenKey, 'r', maxAgeSeconds: 100);
      when(() => auth.me()).thenAnswer((_) async => _me);
      await session.restore();
      expect(session.state, const SessionAuthenticated(_me));
      expect(session.hasSignedInBefore, isTrue);
    });

    test('network failure keeps the tokens and shows Unavailable', () async {
      SharedPreferences.setMockInitialValues({installedFlag: true});
      session = SessionCubit(
        auth: auth,
        tokens: tokens,
        prefs: await SharedPreferences.getInstance(),
      );
      await tokens.save(refreshTokenKey, 'r', maxAgeSeconds: 100);
      when(() => auth.me()).thenThrow(
        const ApiException(kind: ApiErrorKind.network, message: 'offline'),
      );
      await session.restore();
      expect(session.state, isA<SessionUnavailable>());
      expect(await tokens.refreshToken(), 'r');
    });

    test('401 that refresh could not fix clears tokens', () async {
      SharedPreferences.setMockInitialValues({installedFlag: true});
      session = SessionCubit(
        auth: auth,
        tokens: tokens,
        prefs: await SharedPreferences.getInstance(),
      );
      await tokens.save(refreshTokenKey, 'r', maxAgeSeconds: 100);
      when(() => auth.me()).thenThrow(_err('token_invalid', status: 401));
      await session.restore();
      expect(session.state, const SessionUnauthenticated());
      expect(await tokens.refreshToken(), isNull);
    });

    test('first run wipes tokens left over from a previous install', () async {
      await tokens.save(refreshTokenKey, 'stale', maxAgeSeconds: 100);
      await session.restore(); // "installed" flag is missing
      expect(session.state, const SessionUnauthenticated());
      verifyNever(() => auth.me());
    });

    test('expired() is ignored unless signed in', () async {
      session.expired();
      expect(session.state, const SessionUnknown());
    });

    test('web: restore asks the server even with no stored token', () async {
      SharedPreferences.setMockInitialValues({installedFlag: true});
      session = SessionCubit(
        auth: auth,
        tokens: tokens,
        prefs: await SharedPreferences.getInstance(),
        browserCookies: true,
      );
      when(() => auth.me()).thenAnswer((_) async => _me);
      await session.restore();
      expect(session.state, const SessionAuthenticated(_me));

      when(() => auth.me())
          .thenThrow(_err('missing_access_token', status: 401));
      await session.restore();
      expect(session.state, const SessionUnauthenticated());
    });

    test('expired() sets a message; logout clears', () async {
      await session.signedIn(_me);
      session.expired();
      expect(
        session.state,
        const SessionUnauthenticated(message: 'Session expired, sign in again'),
      );
      when(() => auth.logout()).thenAnswer((_) async {});
      await session.logout();
      expect(session.state, const SessionUnauthenticated());
    });
  });
}
