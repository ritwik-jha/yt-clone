import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/validators.dart';
import '../../cubits/auth/auth_cubit.dart';
import '../../cubits/auth/auth_state.dart';
import '../../cubits/session/session_cubit.dart';
import '../../services/auth_service.dart';
import '../../widgets/auth_scaffold.dart';
import 'confirm_signup_page.dart';
import 'login_page.dart';
import 'reset_password_page.dart';

class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key, this.email});

  final String? email;

  static Route<void> route({String? email}) => MaterialPageRoute(
    builder: (ctx) => BlocProvider(
      create: (_) =>
          AuthCubit(ctx.read<AuthService>(), ctx.read<SessionCubit>()),
      child: ForgotPasswordPage(email: email),
    ),
  );

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final _formKey = GlobalKey<FormState>();
  late final emailController = TextEditingController(text: widget.email);

  @override
  void dispose() {
    emailController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    context.read<AuthCubit>().forgotPassword(emailController.text);
  }

  @override
  Widget build(BuildContext context) => BlocConsumer<AuthCubit, AuthState>(
    listener: (context, state) {
      switch (state) {
        case AuthResetCodeSent(:final email, :final message):
          showSnack(context, message);
          Navigator.of(context).pushReplacement(ResetPasswordPage.route(email));
        case AuthError(:final code, :final message):
          if (code != 'validation_error') showSnack(context, message);
        default:
      }
    },
    builder: (context, state) {
      final loading = state is AuthLoading;
      final error = state is AuthError ? state : null;
      return AuthScaffold(
        title: 'Reset your password',
        subtitle: "We'll email you a code",
        showBack: true,
        children: [
          Form(
            key: _formKey,
            child: TextFormField(
              controller: emailController,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              validator: Validators.email,
              onFieldSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: 'Email',
                errorText: error?.fieldErrors['email'],
              ),
            ),
          ),
          if (error?.code == 'invalid_parameter')
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  ConfirmSignUpPage.route(
                    emailController.text.trim().toLowerCase(),
                    sendCodeOnOpen: true,
                  ),
                ),
                child: const Text('Verify email'),
              ),
            ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: loading ? null : _submit,
            child: LoadingLabel(loading: loading, label: 'Send code'),
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
