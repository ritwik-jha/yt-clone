import 'dart:async';

import 'package:flutter/material.dart';

/// "Resend code" with an app-side cooldown (plan §6.2).
class ResendCodeButton extends StatefulWidget {
  const ResendCodeButton({
    super.key,
    required this.onResend,
    this.startCooldown = false,
    this.cooldownSeconds = 60,
    this.enabled = true,
  });

  final VoidCallback onResend;
  final bool startCooldown;
  final int cooldownSeconds;
  final bool enabled;

  @override
  State<ResendCodeButton> createState() => ResendCodeButtonState();
}

class ResendCodeButtonState extends State<ResendCodeButton> {
  Timer? _timer;
  int _remaining = 0;

  @override
  void initState() {
    super.initState();
    if (widget.startCooldown) startCooldown();
  }

  void startCooldown() {
    _timer?.cancel();
    setState(() => _remaining = widget.cooldownSeconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _remaining--);
      if (_remaining <= 0) t.cancel();
    });
  }

  /// e.g. on `code_expired`, so Resend works at once.
  void clearCooldown() {
    _timer?.cancel();
    if (mounted) setState(() => _remaining = 0);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cooling = _remaining > 0;
    return TextButton(
      onPressed: cooling || !widget.enabled ? null : widget.onResend,
      child: Text(cooling ? 'Resend in $_remaining s' : 'Resend code'),
    );
  }
}
