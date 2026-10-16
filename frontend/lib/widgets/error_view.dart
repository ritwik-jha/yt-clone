import 'package:flutter/material.dart';

import '../core/api_exception.dart';
import '../core/theme.dart';

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.message, this.onRetry, this.icon});

  factory ErrorView.fromException(
    ApiException e, {
    Key? key,
    VoidCallback? onRetry,
  }) {
    final icon = e.isNetwork
        ? Icons.wifi_off_rounded
        : Icons.error_outline_rounded;
    final msg = switch (e.kind) {
      ApiErrorKind.unavailable => 'Service temporarily unavailable',
      ApiErrorKind.server => 'Something went wrong\n${e.message}',
      _ => e.message,
    };
    return ErrorView(key: key, message: msg, onRetry: onRetry, icon: icon);
  }

  final String message;
  final VoidCallback? onRetry;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon ?? Icons.error_outline_rounded,
            size: 48,
            color: YtColors.textSecondary,
          ),
          const SizedBox(height: 16),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: YtColors.textSecondary),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 20),
            OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ],
      ),
    ),
  );
}
