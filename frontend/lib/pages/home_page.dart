import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../core/theme.dart';
import '../cubits/channel/channel_cubit.dart';
import '../cubits/feed/feed_cubit.dart';
import '../cubits/feed/feed_state.dart';
import '../models/video.dart';
import '../services/video_service.dart';
import '../widgets/chip_bar.dart';
import '../widgets/video_grid.dart';

/// The mockup's home: a pinned chip bar over the video grid.
///
/// "All" is the public feed, newest first; "Most viewed" sorts it by views;
/// then one chip per creator in the feed narrows the grid to their videos.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

const _all = 'all';
const _popular = 'popular';

class _HomePageState extends State<HomePage> {
  late final FeedCubit _feed = FeedCubit(context.read<VideoService>())..load();
  String _selected = _all;

  /// Creators from the first page of the feed, in feed order. Fixed once
  /// known, so the chips don't move while the user picks one.
  List<Creator>? _creators;

  @override
  void dispose() {
    _feed.close();
    super.dispose();
  }

  void _noteCreators(VideoListState state) {
    if (_creators != null || state.status != ListStatus.success) return;
    final seen = <String>{};
    setState(() {
      _creators = [
        for (final v in state.items)
          if (seen.add(v.creator.id)) v.creator,
      ].take(12).toList();
    });
  }

  FeedCubit _create(BuildContext context) {
    final videos = context.read<VideoService>();
    return switch (_selected) {
      _popular => FeedCubit(videos, sort: VideoSort.popular),
      final creatorId => ChannelCubit(videos, creatorId),
    }..load();
  }

  @override
  Widget build(BuildContext context) => BlocListener<FeedCubit, VideoListState>(
    bloc: _feed,
    listener: (_, state) => _noteCreators(state),
    child: _selected == _all
        ? BlocProvider.value(value: _feed, child: _body())
        : BlocProvider<FeedCubit>(
            key: ValueKey(_selected),
            create: _create,
            child: _body(),
          ),
  );

  Widget _body() => Builder(
    builder: (context) => LoadMoreListener(
      onNearEnd: () => context.read<FeedCubit>().loadMore(),
      child: RefreshIndicator(
        onRefresh: () => context.read<FeedCubit>().refresh(),
        child: CustomScrollView(
          slivers: [
            SliverPersistentHeader(
              pinned: true,
              delegate: _ChipHeader(
                ChipBar<String>(
                  options: [
                    const ChipOption(_all, 'All'),
                    const ChipOption(_popular, 'Most viewed'),
                    for (final c in _creators ?? const <Creator>[])
                      ChipOption(c.id, c.name),
                  ],
                  selected: _selected,
                  onSelected: (value) => setState(() => _selected = value),
                ),
              ),
            ),
            const SliverPadding(
              padding: EdgeInsets.fromLTRB(24, 24, 24, 32),
              sliver: VideoGridSliver<FeedCubit>(
                empty: 'No videos yet. Upload the first one!',
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ChipHeader extends SliverPersistentHeaderDelegate {
  _ChipHeader(this.chips);
  final Widget chips;

  @override
  double get minExtent => YtSizes.chipBarHeight + 1;
  @override
  double get maxExtent => YtSizes.chipBarHeight + 1;

  @override
  Widget build(BuildContext context, double shrink, bool overlaps) => Container(
    height: maxExtent,
    decoration: const BoxDecoration(
      color: YtColors.surface,
      border: Border(top: BorderSide(color: YtColors.divider)),
    ),
    child: chips,
  );

  @override
  bool shouldRebuild(_ChipHeader old) => old.chips != chips;
}
