import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Grey blocks shaped like a [VideoGridCard], shown while the first page
/// loads.
class GridCardSkeleton extends StatelessWidget {
  const GridCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) => const Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      AspectRatio(aspectRatio: 16 / 9, child: _Block()),
      SizedBox(height: 12),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Block(width: 36, height: 36, circle: true),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Block(height: 16),
                SizedBox(height: 8),
                FractionallySizedBox(
                  widthFactor: 0.6,
                  child: _Block(height: 14),
                ),
              ],
            ),
          ),
        ],
      ),
    ],
  );
}

class ListTileSkeleton extends StatelessWidget {
  const ListTileSkeleton({super.key, this.thumbWidth = 168});
  final double thumbWidth;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: thumbWidth,
        child: const AspectRatio(aspectRatio: 16 / 9, child: _Block()),
      ),
      const SizedBox(width: 8),
      const Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Block(height: 14),
            SizedBox(height: 8),
            FractionallySizedBox(widthFactor: 0.5, child: _Block(height: 12)),
          ],
        ),
      ),
    ],
  );
}

class _Block extends StatelessWidget {
  const _Block({this.width, this.height, this.circle = false});
  final double? width;
  final double? height;
  final bool circle;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: YtColors.surfaceHigh,
        shape: circle ? BoxShape.circle : BoxShape.rectangle,
      ),
    ),
  );
}
