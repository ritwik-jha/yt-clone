import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../core/theme.dart';
import '../models/watch_progress.dart';
import '../services/watch_progress_store.dart';

/// The red bar along the bottom of a thumbnail: how much of [videoId] the
/// signed-in user has watched. Nothing while signed out or never watched.
class WatchedBar extends StatefulWidget {
  const WatchedBar({super.key, required this.videoId});

  final String videoId;

  @override
  State<WatchedBar> createState() => _WatchedBarState();
}

class _WatchedBarState extends State<WatchedBar> {
  WatchProgressStore? _store;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _store ??= _find(context);
  }

  /// Null outside the app (a widget pumped on its own in a test).
  static WatchProgressStore? _find(BuildContext context) {
    try {
      return context.read<WatchProgressStore>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    if (store == null) return const SizedBox.shrink();
    return ValueListenableBuilder<bool>(
      valueListenable: store.active,
      builder: (context, active, _) {
        if (!active) return const SizedBox.shrink();
        // Looked up once per video; this only subscribes afterwards.
        return ValueListenableBuilder<WatchProgress?>(
          valueListenable: store.watch(widget.videoId),
          builder: (context, p, _) => _bar(p?.fraction ?? 0),
        );
      },
    );
  }

  Widget _bar(double fraction) {
    if (fraction <= 0) return const SizedBox.shrink();
    final percent = (fraction * 100).round();
    return Semantics(
      label: 'Watched $percent%',
      child: SizedBox(
        height: YtSizes.watchedBarHeight,
        child: ColoredBox(
          color: YtColors.watchedTrack,
          child: Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              key: ValueKey('watched-${widget.videoId}'),
              widthFactor: fraction,
              heightFactor: 1,
              child: const ColoredBox(color: YtColors.red),
            ),
          ),
        ),
      ),
    );
  }
}
