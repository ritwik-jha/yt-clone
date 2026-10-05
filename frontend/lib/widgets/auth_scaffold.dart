import 'package:flutter/material.dart';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../core/server_settings.dart';
import '../core/theme.dart';
import 'brand_mark.dart';
import 'server_url_dialog.dart';

/// Shared layout for the auth screens: logo mark, title, form.
class AuthScaffold extends StatelessWidget {
  const AuthScaffold({
    super.key,
    required this.title,
    this.subtitle,
    required this.children,
    this.showBack = false,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;
  final bool showBack;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: showBack
        ? AppBar(
            actions: [
              ServerUrlButton(settings: context.read<ServerSettings>()),
            ],
          )
        : null,
    body: SafeArea(
      child: Stack(
        children: [
          Positioned.fill(child: _form()),
          if (!showBack)
            Positioned(
              top: 0,
              right: 4,
              child: ServerUrlButton(settings: context.read<ServerSettings>()),
            ),
        ],
      ),
    ),
  );

  Widget _form() => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _LogoMark(),
            const SizedBox(height: 28),
            Text(
              title,
              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                style: const TextStyle(color: YtColors.textSecondary),
              ),
            ],
            const SizedBox(height: 24),
            ...children,
          ],
        ),
      ),
    ),
  );
}

class _LogoMark extends StatelessWidget {
  const _LogoMark();

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.start,
    children: [
      const BrandMark(size: 36),
      const SizedBox(width: 8),
      const Text(
        'Video Stream',
        style: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
        ),
      ),
    ],
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
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
        )
      : Text(label);
}

void showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
