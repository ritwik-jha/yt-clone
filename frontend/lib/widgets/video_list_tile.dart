import 'package:flutter/material.dart';

import '../app/routes.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../models/video.dart';
import 'avatar.dart';
import 'link.dart';
import 'video_thumbnail.dart';

/// A video as a row: thumbnail on the left, details on the right. Compact
/// for the watch page's up-next column, large for search results.
class VideoListTile extends StatelessWidget {
  const VideoListTile({
    super.key,
    required this.video,
    this.large = false,
    this.meta,
    this.trailing,
  });

  final Video video;
  final bool large;

  /// Replaces the "views • age" line (History: "Watched 2 hours ago").
  final String? meta;

  /// At the end of the row (History: remove from watch history).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall!;
    final metaStyle = large ? small : small.copyWith(fontSize: 12);
    final metaLine = meta ?? viewsAndAge(video.viewsCount, video.createdAt);
    final watch = Routes.watch(video.id);
    final channel = Routes.channel(video.creator.id);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: large ? 360 : 168,
          child: AppLink(
            location: watch,
            semanticLabel: video.title,
            child: VideoThumbnail(
              url: video.thumbnailUrl,
              durationSeconds: video.durationSeconds,
              videoId: video.id,
            ),
          ),
        ),
        SizedBox(width: large ? 16 : 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppLink(
                location: watch,
                child: Text(
                  video.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: large ? 18 : 14,
                    height: 1.35,
                    fontWeight: large ? FontWeight.w400 : FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              if (large) ...[
                Text(metaLine, style: metaStyle),
                const SizedBox(height: 12),
                AppLink(
                  location: channel,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Avatar(
                        name: video.creator.name,
                        seed: video.creator.id,
                        size: 24,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          video.creator.name,
                          overflow: TextOverflow.ellipsis,
                          style: metaStyle,
                        ),
                      ),
                    ],
                  ),
                ),
                if ((video.description ?? '').isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    video.description!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: metaStyle.copyWith(fontSize: 12),
                  ),
                ],
              ] else ...[
                AppLink(
                  location: channel,
                  child: Text(
                    video.creator.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: metaStyle,
                  ),
                ),
                Text(
                  metaLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: metaStyle,
                ),
              ],
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }
}

/// Section label with a "▶ PLAY ALL" link, as on the mockup's channel page.
class ShelfHeader extends StatelessWidget {
  const ShelfHeader({super.key, required this.title, this.playAll});

  final String title;

  /// Where PLAY ALL goes (the shelf's first video); hidden when null.
  final String? playAll;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Text(
        title,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      if (playAll != null) ...[
        const SizedBox(width: 24),
        AppLink(
          location: playAll!,
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.play_arrow, color: YtColors.textSecondary, size: 22),
              SizedBox(width: 6),
              Text(
                'PLAY ALL',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: YtColors.textSecondary,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ],
    ],
  );
}
