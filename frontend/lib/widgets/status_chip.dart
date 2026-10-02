import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../models/video.dart';

class _Chip extends StatelessWidget {
  const _Chip(this.label, this.color, {this.icon});
  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
        ],
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key});
  final VideoStatus status;

  @override
  Widget build(BuildContext context) => _Chip(status.label, switch (status) {
    VideoStatus.completed => YtColors.success,
    VideoStatus.failed => const Color(0xFFFF6E6E),
    VideoStatus.pending || VideoStatus.processing => YtColors.warning,
    VideoStatus.unknown => YtColors.textSecondary,
  });
}

class VisibilityChip extends StatelessWidget {
  const VisibilityChip(this.visibility, {super.key});
  final VideoVisibility visibility;

  @override
  Widget build(BuildContext context) => _Chip(
    visibility.label,
    YtColors.textSecondary,
    icon: switch (visibility) {
      VideoVisibility.public => Icons.public,
      VideoVisibility.private => Icons.lock_outline,
      VideoVisibility.unlisted => Icons.link,
      VideoVisibility.unknown => Icons.help_outline,
    },
  );
}
