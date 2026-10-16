import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../core/theme.dart';
import '../cubits/feed/feed_cubit.dart';
import '../cubits/feed/feed_state.dart';
import 'error_view.dart';
import 'skeletons.dart';
import 'video_grid_card.dart';

/// Column count and tile height for a grid [width] wide: as many columns of
/// at least [YtSizes.gridMinTileWidth] as fit, up to [maxColumns]. The text
/// under the thumbnail grows with [textScaler] (the browser's font size).
({int columns, double extent}) gridLayout(
  double width, {
  int maxColumns = 6,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  const gap = YtSizes.gridGap;
  final columns = math
      .max(1, ((width + gap) / (YtSizes.gridMinTileWidth + gap)).floor())
      .clamp(1, maxColumns);
  final tile = (width - gap * (columns - 1)) / columns;
  // Thumbnail, gap, then up to two title lines and two meta lines.
  return (columns: columns, extent: tile * 9 / 16 + 12 + textScaler.scale(84));
}

/// The [FeedCubit] of type [C] above as a sliver grid of [VideoGridCard]s,
/// with skeletons while loading, and the error or [empty] message.
class VideoGridSliver<C extends FeedCubit> extends StatelessWidget {
  const VideoGridSliver({
    super.key,
    this.showAvatar = true,
    this.empty = 'No videos yet.',
    this.maxColumns = 6,
  });

  final bool showAvatar;
  final String empty;
  final int maxColumns;

  @override
  Widget build(BuildContext context) => BlocBuilder<C, VideoListState>(
    builder: (context, state) => SliverLayoutBuilder(
      builder: (context, constraints) {
        final layout = gridLayout(
          constraints.crossAxisExtent,
          maxColumns: maxColumns,
          textScaler: MediaQuery.textScalerOf(context),
        );
        final delegate = SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: layout.columns,
          crossAxisSpacing: YtSizes.gridGap,
          mainAxisSpacing: 24,
          mainAxisExtent: layout.extent,
        );
        if (state.status == ListStatus.initial ||
            state.status == ListStatus.loading) {
          return SliverGrid(
            gridDelegate: delegate,
            delegate: SliverChildBuilderDelegate(
              (_, _) => const GridCardSkeleton(),
              childCount: layout.columns * 2,
            ),
          );
        }
        if (state.status == ListStatus.failure && state.error != null) {
          return SliverFillRemaining(
            hasScrollBody: false,
            child: ErrorView.fromException(
              state.error!,
              onRetry: () => context.read<C>().load(),
            ),
          );
        }
        if (state.items.isEmpty) {
          return SliverFillRemaining(
            hasScrollBody: false,
            child: ErrorView(
              message: empty,
              icon: Icons.video_library_outlined,
            ),
          );
        }
        return SliverMainAxisGroup(
          slivers: [
            SliverGrid(
              gridDelegate: delegate,
              delegate: SliverChildBuilderDelegate(
                (context, i) => VideoGridCard(
                  key: ValueKey(state.items[i].id),
                  video: state.items[i],
                  showAvatar: showAvatar,
                ),
                childCount: state.items.length,
              ),
            ),
            if (state.status == ListStatus.loadingMore)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ),
          ],
        );
      },
    ),
  );
}

/// Calls [onNearEnd] when a vertical scroll comes within a screen of its end.
class LoadMoreListener extends StatelessWidget {
  const LoadMoreListener({
    super.key,
    required this.onNearEnd,
    required this.child,
  });

  final VoidCallback onNearEnd;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.axis == Axis.vertical &&
              n.metrics.extentAfter < n.metrics.viewportDimension) {
            onNearEnd();
          }
          return false;
        },
        child: child,
      );
}

/// [sliver] at most [maxWidth] wide, centred in the scroll view.
class CenteredSliver extends StatelessWidget {
  const CenteredSliver({
    super.key,
    required this.maxWidth,
    required this.sliver,
  });

  final double maxWidth;
  final Widget sliver;

  @override
  Widget build(BuildContext context) => SliverLayoutBuilder(
    builder: (context, constraints) {
      final side = math.max(0.0, (constraints.crossAxisExtent - maxWidth) / 2);
      return SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: side),
        sliver: sliver,
      );
    },
  );
}
