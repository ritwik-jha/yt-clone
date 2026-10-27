import 'package:flutter/material.dart';

import '../app/routes.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../models/video.dart';
import 'avatar.dart';
import 'link.dart';
import 'video_thumbnail.dart';

/// A video in a grid: thumbnail, then the creator's avatar beside the title,
/// channel name, and "views • age" (the mockup's home grid).
class VideoGridCard extends StatelessWidget {
  const VideoGridCard({super.key, required this.video, this.showAvatar = true});

  final Video video;

  /// Off on a channel's own page, where every video is theirs.
  final bool showAvatar;

  @override
  Widget build(BuildContext context) {
    final watch = Routes.watch(video.id);
    final channel = Routes.channel(video.creator.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppLink(
          location: watch,
          semanticLabel: video.title,
          child: VideoThumbnail(
            url: video.thumbnailUrl,
            durationSeconds: video.durationSeconds,
            videoId: video.id,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showAvatar) ...[
              AppLink(
                location: channel,
                semanticLabel: video.creator.name,
                child: Avatar(
                  name: video.creator.name,
                  seed: video.creator.id,
                  size: YtSizes.avatar,
                ),
              ),
              const SizedBox(width: 12),
            ],
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
                      style: const TextStyle(
                        fontSize: 14,
                        height: 1.4,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (showAvatar)
                    AppLink(
                      location: channel,
                      child: Text(
                        video.creator.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  Text(
                    viewsAndAge(video.viewsCount, video.createdAt),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}
