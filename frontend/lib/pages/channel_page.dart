import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../app/routes.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../cubits/channel/channel_cubit.dart';
import '../cubits/feed/feed_cubit.dart';
import '../cubits/feed/feed_state.dart';
import '../cubits/session/session_cubit.dart';
import '../cubits/session/session_state.dart';
import '../models/video.dart';
import '../services/video_service.dart';
import '../widgets/avatar.dart';
import '../widgets/chip_bar.dart';
import '../widgets/error_view.dart';
import '../widgets/link.dart';
import '../widgets/skeletons.dart';
import '../widgets/video_grid.dart';
import '../widgets/video_grid_card.dart';
import '../widgets/video_list_tile.dart';
import '../widgets/video_thumbnail.dart';

enum ChannelTab { home, videos }

/// `/channel/<user id>` (HOME) and `/channel/<user id>/videos` (VIDEOS), as
/// in the mockup: avatar, name, and tabs on the grey header; on HOME the
/// latest upload featured beside its description, then "Uploads" and
/// "Popular uploads" shelves with PLAY ALL.
class ChannelPage extends StatefulWidget {
  const ChannelPage({
    super.key,
    required this.userId,
    this.tab = ChannelTab.home,
  });

  final String userId;
  final ChannelTab tab;

  @override
  State<ChannelPage> createState() => _ChannelPageState();
}

class _ChannelPageState extends State<ChannelPage> {
  late final VideoService _videos = context.read<VideoService>();
  late final ChannelCubit _latest = ChannelCubit(_videos, widget.userId)
    ..load();
  late final ChannelCubit _popular = ChannelCubit(
    _videos,
    widget.userId,
    sort: VideoSort.popular,
    limit: 12,
  )..load();
  VideoSort _sort = VideoSort.latest;

  @override
  void dispose() {
    _latest.close();
    _popular.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      BlocBuilder<ChannelCubit, VideoListState>(
        bloc: _latest,
        builder: (context, state) {
          if (state.status == ListStatus.failure && state.error != null) {
            return state.error!.code == 'channel_not_found' ||
                    state.error!.code == 'validation_error'
                ? const ErrorView(
                    message: "This channel doesn't exist.",
                    icon: Icons.person_off_outlined,
                  )
                : ErrorView.fromException(state.error!, onRetry: _latest.load);
          }
          final creator = _latest.creator;
          final scroll = CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: _Header(
                  creator: creator,
                  total: state.status == ListStatus.success
                      ? state.total
                      : null,
                  userId: widget.userId,
                  tab: widget.tab,
                ),
              ),
              if (widget.tab == ChannelTab.home)
                ..._home(state)
              else
                ..._videosTab(),
            ],
          );
          if (widget.tab == ChannelTab.home) return scroll;
          return BlocProvider<FeedCubit>(
            key: ValueKey(_sort),
            create: (_) =>
                ChannelCubit(_videos, widget.userId, sort: _sort)..load(),
            child: Builder(
              builder: (context) => LoadMoreListener(
                onNearEnd: () => context.read<FeedCubit>().loadMore(),
                child: scroll,
              ),
            ),
          );
        },
      );

  List<Widget> _home(VideoListState state) {
    if (state.status != ListStatus.success) {
      return [
        const SliverPadding(
          padding: EdgeInsets.all(24),
          sliver: SliverToBoxAdapter(child: ListTileSkeleton(thumbWidth: 424)),
        ),
      ];
    }
    if (state.items.isEmpty) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: ErrorView(
            message: 'This channel has no videos yet.',
            icon: Icons.video_library_outlined,
          ),
        ),
      ];
    }
    return [
      SliverToBoxAdapter(
        child: _Section(child: _Featured(video: state.items.first)),
      ),
      SliverToBoxAdapter(
        child: _Section(
          child: _Shelf(title: 'Uploads', videos: state.items),
        ),
      ),
      if (state.items.length > 1)
        SliverToBoxAdapter(
          child: BlocBuilder<ChannelCubit, VideoListState>(
            bloc: _popular,
            builder: (context, popular) => popular.items.isEmpty
                ? const SizedBox.shrink()
                : _Section(
                    child: _Shelf(
                      title: 'Popular uploads',
                      videos: popular.items,
                    ),
                  ),
          ),
        ),
      const SliverToBoxAdapter(child: SizedBox(height: 48)),
    ];
  }

  List<Widget> _videosTab() => [
    SliverToBoxAdapter(
      child: _Constrained(
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: ChipBar<VideoSort>(
            padding: EdgeInsets.zero,
            options: const [
              ChipOption(VideoSort.latest, 'Recently uploaded'),
              ChipOption(VideoSort.popular, 'Popular'),
            ],
            selected: _sort,
            onSelected: (s) => setState(() => _sort = s),
          ),
        ),
      ),
    ),
    const SliverPadding(
      padding: EdgeInsets.fromLTRB(24, 16, 24, 48),
      sliver: CenteredSliver(
        maxWidth: 1236,
        sliver: VideoGridSliver<FeedCubit>(
          showAvatar: false,
          empty: 'This channel has no videos yet.',
        ),
      ),
    ),
  ];
}

/// Centres content at the mockup's 1284px channel width.
class _Constrained extends StatelessWidget {
  const _Constrained({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1284),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: child,
      ),
    ),
  );
}

class _Section extends StatelessWidget {
  const _Section({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => _Constrained(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 24),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: YtColors.divider)),
      ),
      child: child,
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header({
    required this.creator,
    required this.total,
    required this.userId,
    required this.tab,
  });

  final Creator? creator;
  final int? total;
  final String userId;
  final ChannelTab tab;

  @override
  Widget build(BuildContext context) {
    final mine = context.select<SessionCubit, bool>(
      (s) => switch (s.state) {
        SessionAuthenticated(:final user) => user.id == userId,
        _ => false,
      },
    );
    final c = creator;
    final facts = [
      if (total != null) total == 1 ? '1 video' : '$total videos',
      if (c?.createdAt != null) formatJoined(c!.createdAt!),
    ].join(' • ');
    return ColoredBox(
      color: YtColors.surface,
      child: _Constrained(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 24),
            Row(
              children: [
                if (c == null)
                  const SizedBox(width: 80, height: 80)
                else
                  Avatar(name: c.name, seed: c.id, size: 80),
                const SizedBox(width: 24),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(c?.name ?? '', style: const TextStyle(fontSize: 24)),
                      const SizedBox(height: 4),
                      Text(facts, style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
                if (mine)
                  FilledButton(
                    onPressed: () => context.go(Routes.myVideos),
                    child: const Text('MANAGE VIDEOS'),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _Tab(
                  label: 'HOME',
                  selected: tab == ChannelTab.home,
                  location: Routes.channel(userId),
                ),
                _Tab(
                  label: 'VIDEOS',
                  selected: tab == ChannelTab.videos,
                  location: Routes.channel(userId, videos: true),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.selected,
    required this.location,
  });

  final String label;
  final bool selected;
  final String location;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    child: AppLink(
      location: location,
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 32),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? const Color(0xFFB8B8B8) : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.5,
            color: selected ? YtColors.textPrimary : YtColors.textSecondary,
          ),
        ),
      ),
    ),
  );
}

/// The latest upload, large, beside its title and description.
class _Featured extends StatelessWidget {
  const _Featured({required this.video});
  final Video video;

  @override
  Widget build(BuildContext context) {
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppLink(
          location: Routes.watch(video.id),
          child: Text(
            video.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 18),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          viewsAndAge(video.viewsCount, video.createdAt),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if ((video.description ?? '').isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            video.description!,
            maxLines: 5,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, height: 1.5),
          ),
        ],
      ],
    );
    final thumb = AppLink(
      location: Routes.watch(video.id),
      semanticLabel: video.title,
      child: VideoThumbnail(
        url: video.thumbnailUrl,
        durationSeconds: video.durationSeconds,
      ),
    );
    return LayoutBuilder(
      builder: (context, c) => c.maxWidth < 720
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [thumb, const SizedBox(height: 12), details],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 424, child: thumb),
                const SizedBox(width: 24),
                Expanded(child: details),
              ],
            ),
    );
  }
}

/// One row of cards under a "Title ▶ PLAY ALL" header.
class _Shelf extends StatelessWidget {
  const _Shelf({required this.title, required this.videos});
  final String title;
  final List<Video> videos;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ShelfHeader(title: title, playAll: Routes.watch(videos.first.id)),
      const SizedBox(height: 16),
      LayoutBuilder(
        builder: (context, c) {
          final layout = gridLayout(
            c.maxWidth,
            maxColumns: 5,
            textScaler: MediaQuery.textScalerOf(context),
          );
          final width =
              (c.maxWidth - YtSizes.gridGap * (layout.columns - 1)) /
              layout.columns;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (i, v) in videos.take(layout.columns).indexed) ...[
                if (i > 0) const SizedBox(width: YtSizes.gridGap),
                SizedBox(
                  width: width,
                  height: layout.extent,
                  child: VideoGridCard(video: v, showAvatar: false),
                ),
              ],
            ],
          );
        },
      ),
    ],
  );
}
