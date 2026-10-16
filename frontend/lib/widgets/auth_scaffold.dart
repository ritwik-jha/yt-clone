import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../app/routes.dart';
import '../core/theme.dart';
import 'brand_logo.dart';

/// Shared layout for the auth pages: a card centred on the page, with the
/// logo (a link home), title, subtitle, and the form.
class AuthScaffold extends StatelessWidget {
  const AuthScaffold({
    super.key,
    required this.title,
    this.subtitle,
    required this.children,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 448),
          child: Container(
            padding: const EdgeInsets.fromLTRB(40, 40, 40, 32),
            decoration: BoxDecoration(
              color: YtColors.surface,
              border: Border.all(color: YtColors.divider),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: InkWell(
                    onTap: () => context.go(Routes.home),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: BrandLogo(height: 24),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 24),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    subtitle!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: YtColors.textSecondary),
                  ),
                ],
                const SizedBox(height: 32),
                ...children,
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// A password field with a show/hide toggle.
class PasswordField extends StatefulWidget {
  const PasswordField({
    super.key,
    required this.controller,
    required this.validator,
    this.label = 'Password',
    this.autofillHint = AutofillHints.password,
    this.errorText,
    this.textInputAction,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String? Function(String?) validator;
  final String label;
  final String autofillHint;
  final String? errorText;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: widget.controller,
    obscureText: _obscure,
    validator: widget.validator,
    autofillHints: [widget.autofillHint],
    textInputAction: widget.textInputAction,
    onFieldSubmitted: widget.onSubmitted,
    decoration: InputDecoration(
      labelText: widget.label,
      errorText: widget.errorText,
      suffixIcon: IconButton(
        tooltip: _obscure ? 'Show password' : 'Hide password',
        icon: Icon(
          _obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
        ),
        onPressed: () => setState(() => _obscure = !_obscure),
      ),
    ),
  );
}

class LoadingLabel extends StatelessWidget {
  const LoadingLabel({super.key, required this.loading, required this.label});
  final bool loading;
  final String label;

  @override
  Widget build(BuildContext context) => loading
      ? const SizedBox(
          height: 20,
          width: 20,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
        )
      : Text(label);
}

void showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
