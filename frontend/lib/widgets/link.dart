import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Makes [child] a link to [location]: pointer cursor, and a tap navigates.
/// Browse pages push nothing, they `go`, so Back is the browser's.
class AppLink extends StatelessWidget {
  const AppLink({
    super.key,
    required this.location,
    required this.child,
    this.semanticLabel,
  });

  final String location;
  final Widget child;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => Semantics(
    link: true,
    label: semanticLabel,
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => context.go(location),
        child: child,
      ),
    ),
  );
}
