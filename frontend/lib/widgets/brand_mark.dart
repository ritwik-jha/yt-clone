import 'package:flutter/material.dart';

import '../core/theme.dart';

/// The app's logo: a red disc with a play triangle.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 32});
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: YtColors.red,
        shape: BoxShape.circle,
      ),
      child: Icon(
        Icons.play_arrow_rounded,
        color: Colors.white,
        size: size * 0.66,
      ),
    ),
  );
}
