import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Pulsing placeholder cards while the first page loads.
class VideoListSkeleton extends StatefulWidget {
  const VideoListSkeleton({super.key, this.count = 4});
  final int count;

  @override
  State<VideoListSkeleton> createState() => _VideoListSkeletonState();
}

class _VideoListSkeletonState extends State<VideoListSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Loading videos',
    child: ExcludeSemantics(
      child: FadeTransition(
        opacity: Tween(begin: 0.45, end: 1.0).animate(_pulse),
        child: ListView.builder(
          physics: const NeverScrollableScrollPhysics(),
          itemCount: widget.count,
          itemBuilder: (_, _) => const _SkeletonCard(),
        ),
      ),
    ),
  );
}

class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard();

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const AspectRatio(
        aspectRatio: 16 / 9,
        child: ColoredBox(color: YtColors.surfaceHigh),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const CircleAvatar(
              radius: 18,
              backgroundColor: YtColors.surfaceHigh,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _bar(double.infinity, 14),
                  const SizedBox(height: 8),
                  _bar(180, 12),
                ],
              ),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _bar(double width, double height) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: YtColors.surfaceHigh,
      borderRadius: BorderRadius.circular(4),
    ),
  );
}
