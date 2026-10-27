import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/theme.dart';
import 'watched_bar.dart';

/// A 16:9 thumbnail with the duration badge in the corner, and the red
/// "watched" bar along the bottom when [videoId] is given.
class VideoThumbnail extends StatelessWidget {
  const VideoThumbnail({
    super.key,
    required this.url,
    this.durationSeconds,
    this.radius = 0,
    this.overlay,
    this.videoId,
  });

  final String url;
  final double? durationSeconds;
  final double radius;

  /// Draws how much of this video the signed-in user has watched.
  final String? videoId;

  /// Drawn over the picture, e.g. a processing badge.
  final Widget? overlay;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: YtColors.surfaceHigh),
          if (url.isNotEmpty)
            Image.network(
              url,
              fit: BoxFit.cover,
              // The thumbnails CDN may not send CORS headers; fall back to an
              // <img> element rather than show nothing.
              webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
              errorBuilder: (_, _, _) => const _Placeholder(),
              frameBuilder: (context, child, frame, sync) => AnimatedOpacity(
                opacity: sync || frame != null ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: child,
              ),
            )
          else
            const _Placeholder(),
          ?overlay,
          if (videoId != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: WatchedBar(videoId: videoId!),
            ),
          if (durationSeconds != null && durationSeconds! > 0)
            Positioned(
              right: 4,
              bottom: 4 + (videoId == null ? 0 : YtSizes.watchedBarHeight),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: YtColors.badge,
                  borderRadius: BorderRadius.circular(2),
                ),
                child: Text(
                  formatDuration(durationSeconds!),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: YtColors.surfaceHigh,
    child: Center(
      child: Icon(
        Icons.smart_display_outlined,
        color: YtColors.textSecondary,
        size: 36,
      ),
    ),
  );
}
