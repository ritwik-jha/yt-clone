import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/theme.dart';
import '../models/progress.dart';
import '../models/video.dart';
import 'status_chip.dart';

/// YouTube-style card: edge-to-edge 16:9 thumbnail, avatar, title, meta line.
class VideoCard extends StatelessWidget {
  const VideoCard({
    super.key,
    required this.video,
    required this.onTap,
    this.progress,
    this.trailing,
    this.showOwnerInfo = false,
  });

  final Video video;
  final VoidCallback onTap;
  final Progress? progress;
  final Widget? trailing;

  /// My Videos mode: status + visibility chips, progress bar.
  final bool showOwnerInfo;

  @override
  Widget build(BuildContext context) {
    final status = video.effectiveStatus;
    final meta = [
      if (!showOwnerInfo) video.creator.name,
      if (status == VideoStatus.completed) formatViews(video.viewsCount),
      timeAgo(video.createdAt),
    ].join(' · ');

    return InkWell(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CachedNetworkImage(
                  imageUrl: video.thumbnailUrl,
                  fit: BoxFit.cover,
                  placeholder: (_, _) =>
                      const ColoredBox(color: YtColors.surfaceHigh),
                  errorWidget: (_, _, _) => const ColoredBox(
                    color: YtColors.surfaceHigh,
                    child: Icon(
                      Icons.broken_image_outlined,
                      color: YtColors.textSecondary,
                      size: 36,
                    ),
                  ),
                ),
                if (video.durationSeconds != null)
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.8),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        formatDuration(video.durationSeconds!),
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                if (showOwnerInfo && status.isUnfinished)
                  Positioned.fill(
                    child: ColoredBox(
                      color: Colors.black54,
                      child: Center(
                        child: Text(
                          _pendingLabel(status),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (showOwnerInfo && status.isUnfinished)
            LinearProgressIndicator(
              value:
                  status == VideoStatus.processing ||
                      (progress?.percent ?? 0) > 0
                  ? (progress?.percent ?? 0) / 100
                  : null,
              minHeight: 3,
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 4, 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!showOwnerInfo) ...[
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: YtColors.surfaceHigh,
                    child: Text(
                      video.creator.name.isEmpty
                          ? '?'
                          : video.creator.name[0].toUpperCase(),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        video.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        meta,
                        style: const TextStyle(
                          color: YtColors.textSecondary,
                          fontSize: 12.5,
                        ),
                      ),
                      if (showOwnerInfo) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            StatusChip(status),
                            VisibilityChip(video.effectiveVisibility),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _pendingLabel(VideoStatus status) {
    final pct = progress?.percent ?? 0;
    if (status == VideoStatus.pending && pct == 0) {
      final age = DateTime.now().difference(video.createdAt);
      return age > const Duration(minutes: 15)
          ? 'Taking longer than usual'
          : 'Waiting to process';
    }
    return 'Processing $pct%';
  }
}
