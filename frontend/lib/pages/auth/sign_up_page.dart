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

class SignUpPage extends StatefulWidget {
  const SignUpPage({super.key});

  /// The page wrapped with its own [AuthCubit].
  static Widget provided(BuildContext ctx) => BlocProvider(
    create: (_) => AuthCubit(ctx.read<AuthService>(), ctx.read<SessionCubit>()),
    child: const SignUpPage(),
  );

  static Route<void> route() => MaterialPageRoute(builder: provided);

  @override
  State<SignUpPage> createState() => _SignUpPageState();
}

class _SignUpPageState extends State<SignUpPage> {
  final _formKey = GlobalKey<FormState>();
  final nameController = TextEditingController();
  final emailController = TextEditingController();
  final passwordController = TextEditingController();

  @override
  void dispose() {
    nameController.dispose();
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    context.read<AuthCubit>().signUpUser(
      nameController.text,
      emailController.text,
      passwordController.text,
    );
  }

  @override
  Widget build(BuildContext context) => BlocConsumer<AuthCubit, AuthState>(
    listener: (context, state) {
      switch (state) {
        case AuthSignUpSuccess(:final email, :final codeSent):
          showSnack(
            context,
            codeSent ? 'Check your email for the verification code' : "Account created, but we couldn't send the email. Tap Resend.",
          );
          Navigator.of(context)
              .push(ConfirmSignUpPage.route(email, freshCode: codeSent));
        case AuthError(:final code, :final message, :final fieldErrors):
          if (fieldErrors.isEmpty &&
              code != 'email_exists' &&
              code != 'invalid_password') {
            showSnack(context, message);
          }
        default:
      }
    },
    builder: (context, state) {
      final loading = state is AuthLoading;
      final error = state is AuthError ? state : null;
      final emailExists = error?.code == 'email_exists';
      return AuthScaffold(
        title: 'Create account',
        subtitle: 'Sign up to upload and watch videos',
        children: [
          Form(
            key: _formKey,
            child: Column(
              children: [
                TextFormField(
                  controller: nameController,
                  decoration: InputDecoration(
                    labelText: 'Name',
                    errorText: error?.fieldErrors['name'],
                  ),
                  autofillHints: const [AutofillHints.name],
                  textInputAction: TextInputAction.next,
                  validator: Validators.name,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: emailController,
                  decoration: InputDecoration(
                    labelText: 'Email',
                    errorText: emailExists
                        ? error!.message
                        : error?.fieldErrors['email'],
                  ),
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  textInputAction: TextInputAction.next,
                  validator: Validators.email,
                ),
                if (emailExists)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(
                            context,
                          ).push(LoginPage.route(email: emailController.text)),
                          child: const Text('Sign in'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(context).push(
                            ConfirmSignUpPage.route(
                              emailController.text.trim().toLowerCase(),
                              sendCodeOnOpen: true,
                            ),
                          ),
                          child: const Text('Verify this email'),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 14),
                PasswordField(
                  controller: passwordController,
                  validator: Validators.newPassword,
                  autofillHint: AutofillHints.newPassword,
                  errorText: error?.code == 'invalid_password'
                      ? error!.message
                      : error?.fieldErrors['password'],
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: loading ? null : _submit,
            child: LoadingLabel(loading: loading, label: 'Sign Up'),
          ),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text('Already have an account?'),
              TextButton(
                onPressed: () => Navigator.of(context).push(LoginPage.route()),
                child: const Text('Sign In'),
              ),
            ],
          ),
        ],
      );
    },
  );
}
