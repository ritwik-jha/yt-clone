import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';

import '../../core/theme.dart';
import '../../core/validators.dart';
import '../../cubits/auth/auth_cubit.dart';
import '../../cubits/auth/auth_state.dart';
import '../../cubits/session/session_cubit.dart';
import '../../services/auth_service.dart';
import '../../widgets/auth_scaffold.dart';
import '../../widgets/resend_code_button.dart';

class ResetPasswordPage extends StatefulWidget {
  const ResetPasswordPage({super.key, required this.email});

  final String email;

  /// The page wrapped with its own [AuthCubit].
  static Widget provided({required String email}) => BlocProvider(
    create: (ctx) =>
        AuthCubit(ctx.read<AuthService>(), ctx.read<SessionCubit>()),
    child: ResetPasswordPage(email: email),
  );

  @override
  State<ResetPasswordPage> createState() => _ResetPasswordPageState();
}

class _ResetPasswordPageState extends State<ResetPasswordPage> {
  final _formKey = GlobalKey<FormState>();
  final otpController = TextEditingController();
  final passwordController = TextEditingController();
  final _resendKey = GlobalKey<ResendCodeButtonState>();

  @override
  void dispose() {
    otpController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    context.read<AuthCubit>().resetPassword(
      widget.email,
      otpController.text,
      passwordController.text,
    );
  }

  @override
  Widget build(BuildContext context) => BlocConsumer<AuthCubit, AuthState>(
    listener: (context, state) {
      switch (state) {
        case AuthPasswordResetSuccess(:final email, :final message):
          showSnack(context, message);
          context.go(Routes.signInPage(email: email));
        case AuthCodeSent(:final message):
          showSnack(context, message);
          _resendKey.currentState?.startCooldown();
        case AuthError(:final code, :final message):
          if (code == 'code_expired') _resendKey.currentState?.clearCooldown();
          if (const {
            'not_authorized',
            'invalid_parameter',
            'too_many_attempts',
            'code_delivery_failed',
          }.contains(code)) {
            showSnack(context, message);
          }
        default:
      }
    },
    builder: (context, state) {
      final loading = state is AuthLoading;
      final error = state is AuthError ? state : null;
      return AuthScaffold(
        title: 'Reset password',
        subtitle: 'Enter the code we emailed you and a new password',
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.email,
                  style: const TextStyle(color: YtColors.textSecondary),
                ),
              ),
              TextButton(
                onPressed: () =>
                    context.go(Routes.forgotPasswordPage(email: widget.email)),
                child: const Text('Change'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Form(
            key: _formKey,
            child: Column(
              children: [
                TextFormField(
                  controller: otpController,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  autofillHints: const [AutofillHints.oneTimeCode],
                  validator: Validators.otp,
                  decoration: InputDecoration(
                    labelText: 'Verification code',
                    counterText: '',
                    errorText: switch (error?.code) {
                      'code_mismatch' => 'Invalid code',
                      'code_expired' => error!.message,
                      _ => error?.fieldErrors['otp'],
                    },
                  ),
                ),
                const SizedBox(height: 14),
                PasswordField(
                  controller: passwordController,
                  label: 'New password',
                  autofillHint: AutofillHints.newPassword,
                  validator: Validators.newPassword,
                  errorText: error?.code == 'invalid_password'
                      ? error!.message
                      : error?.fieldErrors['new_password'],
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
                ),
              ],
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: ResendCodeButton(
              key: _resendKey,
              startCooldown: true,
              enabled: !loading,
              onResend: () =>
                  context.read<AuthCubit>().resendResetCode(widget.email),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: loading ? null : _submit,
            child: LoadingLabel(loading: loading, label: 'Reset password'),
          ),
        ],
      );
    },
  );
}
