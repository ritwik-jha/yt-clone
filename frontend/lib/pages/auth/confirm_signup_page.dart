import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/validators.dart';
import '../../cubits/auth/auth_cubit.dart';
import '../../cubits/auth/auth_state.dart';
import '../../cubits/session/session_cubit.dart';
import '../../services/auth_service.dart';
import '../../widgets/auth_scaffold.dart';
import '../../widgets/resend_code_button.dart';
import 'login_page.dart';

class ConfirmSignUpPage extends StatefulWidget {
  const ConfirmSignUpPage({
    super.key,
    required this.email,
    this.freshCode = false,
    this.sendCodeOnOpen = false,
  });

  final String email;

  /// A code was just sent (straight after signup): start the cooldown.
  final bool freshCode;

  /// Opened from Sign In / Sign Up for an unconfirmed account: send a new code.
  final bool sendCodeOnOpen;

  /// The page wrapped with its own [AuthCubit].
  static Widget provided(
    BuildContext ctx, {
    required String email,
    bool freshCode = false,
    bool sendCodeOnOpen = false,
  }) => BlocProvider(
    create: (_) => AuthCubit(ctx.read<AuthService>(), ctx.read<SessionCubit>()),
    child: ConfirmSignUpPage(
      email: email,
      freshCode: freshCode,
      sendCodeOnOpen: sendCodeOnOpen,
    ),
  );

  static Route<void> route(
    String email, {
    bool freshCode = false,
    bool sendCodeOnOpen = false,
  }) => MaterialPageRoute(
    builder: (ctx) => provided(
      ctx,
      email: email,
      freshCode: freshCode,
      sendCodeOnOpen: sendCodeOnOpen,
    ),
  );

  @override
  State<ConfirmSignUpPage> createState() => _ConfirmSignUpPageState();
}

class _ConfirmSignUpPageState extends State<ConfirmSignUpPage> {
  final _formKey = GlobalKey<FormState>();
  late final emailController = TextEditingController(text: widget.email);
  final otpController = TextEditingController();
  final _resendKey = GlobalKey<ResendCodeButtonState>();

  @override
  void initState() {
    super.initState();
    if (widget.sendCodeOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.read<AuthCubit>().resendCode(emailController.text);
      });
    }
  }

  @override
  void dispose() {
    emailController.dispose();
    otpController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    context.read<AuthCubit>().confirmSignUpUser(
      emailController.text,
      otpController.text,
    );
  }

  @override
  Widget build(BuildContext context) => BlocConsumer<AuthCubit, AuthState>(
    listener: (context, state) {
      switch (state) {
        case AuthConfirmSignUpSuccess(:final email):
          showSnack(context, 'User confirmed successfully');
          Navigator.of(context).pushReplacement(LoginPage.route(email: email));
        case AuthCodeSent(:final message):
          showSnack(context, message);
          _resendKey.currentState?.startCooldown();
        case AuthError(:final code, :final message):
          if (code == 'code_expired') _resendKey.currentState?.clearCooldown();
          if (code == 'not_authorized') {
            showSnack(context, 'This account is already verified');
            Navigator.of(context)
                .pushReplacement(LoginPage.route(email: emailController.text));
          } else if (const {
            'code_delivery_failed',
            'too_many_attempts',
            'invalid_parameter',
          }.contains(code)) {
            showSnack(context, message);
          }
        default:
      }
    },
    builder: (context, state) {
      final loading = state is AuthLoading;
      final error = state is AuthError ? state : null;
      final otpError = switch (error?.code) {
        'code_mismatch' || 'code_expired' => error!.message,
        _ => error?.fieldErrors['otp'],
      };
      return AuthScaffold(
        title: 'Confirm Sign Up',
        subtitle: 'Enter the 6-digit code we emailed you',
        showBack: true,
        children: [
          Form(
            key: _formKey,
            child: Column(
              children: [
                TextFormField(
                  controller: emailController,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  validator: Validators.email,
                  decoration: InputDecoration(
                    labelText: 'Email',
                    errorText: error?.code == 'user_not_found'
                        ? 'No account for this email'
                        : error?.fieldErrors['email'],
                  ),
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: otpController,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  autofillHints: const [AutofillHints.oneTimeCode],
                  validator: Validators.otp,
                  onFieldSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    labelText: 'Verification code',
                    counterText: '',
                    errorText: otpError,
                  ),
                ),
              ],
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: ResendCodeButton(
              key: _resendKey,
              startCooldown: widget.freshCode,
              enabled: !loading,
              onResend: () =>
                  context.read<AuthCubit>().resendCode(emailController.text),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: loading ? null : _submit,
            child: LoadingLabel(loading: loading, label: 'Confirm'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => Navigator.of(context)
                .pushReplacement(LoginPage.route(email: emailController.text)),
            child: const Text('Back to sign in'),
          ),
        ],
      );
    },
  );
}
