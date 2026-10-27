import 'dart:async';

import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/theme.dart';

/// "Resumed from 4:14 · START OVER", over the bottom-left of the player for
/// [visibleFor] after the watch page resumed a video.
class ResumeChip extends StatefulWidget {
  const ResumeChip({
    super.key,
    required this.from,
    required this.onStartOver,
    this.visibleFor = const Duration(seconds: 4),
  });

  final Duration from;
  final VoidCallback onStartOver;
  final Duration visibleFor;

  @override
  State<ResumeChip> createState() => _ResumeChipState();
}

class _ResumeChipState extends State<ResumeChip> {
  late final Timer _timer = Timer(widget.visibleFor, _hide);
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    _timer; // started now
  }

  void _hide() {
    if (mounted) setState(() => _visible = false);
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    return Material(
      color: YtColors.badge,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.only(left: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Resumed from ${formatDuration(widget.from.inSeconds)}',
              style: const TextStyle(fontSize: 13, color: Colors.white),
            ),
            const Text(
              '  •',
              style: TextStyle(fontSize: 13, color: YtColors.textSecondary),
            ),
            TextButton(
              onPressed: () {
                widget.onStartOver();
                _hide();
              },
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              child: const Text(
                'START OVER',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
