import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/validators.dart';
import '../../cubits/auth/auth_cubit.dart';
import '../../cubits/auth/auth_state.dart';
import '../../cubits/session/session_cubit.dart';
import '../../cubits/session/session_state.dart';
import '../../services/auth_service.dart';
import '../../widgets/auth_scaffold.dart';
import 'confirm_signup_page.dart';
import 'forgot_password_page.dart';
import 'sign_up_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, this.email});

  final String? email;

  /// The page wrapped with its own [AuthCubit].
  static Widget provided(BuildContext ctx, {String? email}) => BlocProvider(
    create: (_) => AuthCubit(ctx.read<AuthService>(), ctx.read<SessionCubit>()),
    child: LoginPage(email: email),
  );

  static Route<void> route({String? email}) =>
      MaterialPageRoute(builder: (ctx) => provided(ctx, email: email));

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  late final emailController = TextEditingController(text: widget.email);
  final passwordController = TextEditingController();

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    context.read<AuthCubit>().loginUser(
      emailController.text,
      passwordController.text,
    );
  }

  @override
  Widget build(BuildContext context) {
    final sessionMessage = switch (context.read<SessionCubit>().state) {
      SessionUnauthenticated(:final message) => message,
      _ => null,
    };
    return BlocConsumer<AuthCubit, AuthState>(
      listener: (context, state) {
        switch (state) {
          case AuthNeedsVerification(:final email):
            Navigator.of(context)
                .push(ConfirmSignUpPage.route(email, sendCodeOnOpen: true));
          case AuthNeedsPasswordReset(:final email):
            Navigator.of(context).push(ForgotPasswordPage.route(email: email));
          case AuthError(:final code, :final message):
            if (code == 'incorrect_credentials') passwordController.clear();
            if (code == 'too_many_attempts') showSnack(context, message);
          default:
        }
      },
      builder: (context, state) {
        final loading = state is AuthLoading;
        final error = state is AuthError ? state : null;
        final formError =
            error != null &&
                error.fieldErrors.isEmpty &&
                error.code != 'too_many_attempts'
            ? error
            : null;
        return AuthScaffold(
          title: 'Sign In',
          subtitle: sessionMessage ?? 'to continue to Video Stream',
          children: [
            Form(
              key: _formKey,
              child: Column(
                children: [
                  TextFormField(
                    controller: emailController,
                    decoration: InputDecoration(
                      labelText: 'Email',
                      errorText: error?.fieldErrors['email'],
                    ),
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.email],
                    textInputAction: TextInputAction.next,
                    validator: Validators.email,
                  ),
                  const SizedBox(height: 14),
                  PasswordField(
                    controller: passwordController,
                    validator: Validators.loginPassword,
                    errorText: error?.fieldErrors['password'],
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                  ),
                ],
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => Navigator.of(
                  context,
                ).push(ForgotPasswordPage.route(email: emailController.text)),
                child: const Text('Forgot password?'),
              ),
            ),
            if (formError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 18,
                      color: Color(0xFFFF6E6E),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(switch (formError.code) {
                        'user_not_found' => 'No account for this email',
                        'unsupported_challenge' => "This account needs a sign-in step the app doesn't support",
                        _ => formError.message,
                      }, style: const TextStyle(color: Color(0xFFFF6E6E))),
                    ),
                    if (formError.code == 'user_not_found')
                      TextButton(
                        onPressed: () =>
                            Navigator.of(context).push(SignUpPage.route()),
                        child: const Text('Sign up'),
                      ),
                  ],
                ),
              ),
            FilledButton(
              onPressed: loading ? null : _submit,
              child: LoadingLabel(loading: loading, label: 'Sign In'),
            ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text("Don't have an account?"),
                TextButton(
                  onPressed: () =>
                      Navigator.of(context).push(SignUpPage.route()),
                  child: const Text('Sign Up'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
