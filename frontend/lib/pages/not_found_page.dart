import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../app/routes.dart';
import '../core/theme.dart';

class NotFoundPage extends StatelessWidget {
  const NotFoundPage({super.key});

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.travel_explore,
          size: 64,
          color: YtColors.textSecondary,
        ),
        const SizedBox(height: 16),
        const Text(
          "This page isn't available. Sorry about that.",
          style: TextStyle(fontSize: 18),
        ),
        const SizedBox(height: 8),
        Text(
          'Try searching for something else.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 24),
        OutlinedButton(
          onPressed: () => context.go(Routes.home),
          child: const Text('GO HOME'),
        ),
      ],
    ),
  );
}
