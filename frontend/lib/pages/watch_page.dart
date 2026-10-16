import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../app/app.dart';
import '../app/routes.dart';
import '../core/api_exception.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../cubits/channel/channel_cubit.dart';
import '../cubits/feed/feed_cubit.dart';
import '../cubits/feed/feed_state.dart';
import '../cubits/session/session_cubit.dart';
import '../cubits/session/session_state.dart';
import '../cubits/video_detail/video_detail_cubit.dart';
import '../cubits/video_detail/video_detail_state.dart';
import '../models/video.dart';
import '../platform/browser.dart';
import '../platform/video_player.dart';
import '../services/video_service.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/avatar.dart';
import '../widgets/chip_bar.dart';
import '../widgets/edit_video_dialog.dart';
import '../widgets/error_view.dart';
import '../widgets/link.dart';
import '../widgets/player_view.dart';
import '../widgets/skeletons.dart';
import '../widgets/status_chip.dart';
import '../widgets/video_list_tile.dart';
import '../widgets/video_thumbnail.dart';

/// `/watch?v=ID`: the mockup's watch page. Player, title and actions, the
/// channel row with the description, then "up next" in a column on the
/// right (below on narrow screens), with "All" and "From (creator)" chips.
class WatchPage extends StatefulWidget {
  const WatchPage({super.key, required this.videoId});

  final String videoId;

  @override
  State<WatchPage> createState() => _WatchPageState();
}

class _WatchPageState extends State<WatchPage> {
  late final VideoDetailCubit _detail = VideoDetailCubit(
    context.read<VideoService>(),
  )..load(widget.videoId);
  late final PlayerController _player = context.read<PlayerFactory>().create();
  late final Browser _browser = context.read<Browser>();
  final _playerKey = GlobalKey();
  PlaybackSource? _opened;
  bool _counted = false;

  @override
  void initState() {
    super.initState();
    _player.addListener(_onPlayer);
    _browser; // resolved now: dispose() can't look it up
  }

  @override
  void dispose() {
    _player.removeListener(_onPlayer);
    _player.dispose();
    _detail.close();
    if (_browser.fullscreen.value) _browser.setFullscreen(false);
    super.dispose();
  }

  /// One view per page, once playback actually starts (plan D18).
  void _onPlayer() {
    if (!_counted && _player.value.started) {
      _counted = true;
      _detail.recordView();
    }
  }

  void _onDetail(BuildContext context, VideoDetailState state) {
    if (state case VideoDetailReady(:final video)) {
      final source = video.playbackSource;
      if (source != null && source != _opened) {
        _opened = source;
        _player.open(source);
      }
    }
    if (state is VideoDetailDeleted) context.go(Routes.myVideos);
  }

  void _toggleFullscreen() =>
      _browser.setFullscreen(!_browser.fullscreen.value);

  @override
  Widget build(BuildContext context) =>
      BlocConsumer<VideoDetailCubit, VideoDetailState>(
        bloc: _detail,
        listener: _onDetail,
        builder: (context, state) => ValueListenableBuilder<bool>(
          valueListenable: _browser.fullscreen,
          builder: (context, fullscreen, _) {
            final player = _PlayerArea(
              key: _playerKey,
              state: state,
              controller: _player,
              fullscreen: fullscreen,
              onToggleFullscreen: _toggleFullscreen,
            );
            if (fullscreen) return player;
            return ColoredBox(
              color: YtColors.watchBackground,
              child: switch (state) {
                VideoDetailNotFound() ||
                VideoDetailDeleted() => const _Unavailable(),
                VideoDetailError(:final error, video: null) =>
                  ErrorView.fromException(
                    error,
                    onRetry: () => _detail.load(widget.videoId),
                  ),
                _ => _Layout(
                  player: player,
                  details: _Details(state: state, cubit: _detail),
                  upNext: _UpNext(state: state, currentId: widget.videoId),
                ),
              },
            );
          },
        ),
      );
}

/// Primary column (player + details) beside the up-next column when there
/// is room; stacked otherwise.
class _Layout extends StatelessWidget {
  const _Layout({
    required this.player,
    required this.details,
    required this.upNext,
  });

  final Widget player;
  final Widget details;
  final Widget upNext;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final height = constraints.maxHeight;
      if (constraints.maxWidth >= 1000) {
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 48),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1754),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _sized(player, maxHeight: height - 120),
                        details,
                      ],
                    ),
                  ),
                  const SizedBox(width: 24),
                  SizedBox(width: 402, child: upNext),
                ],
              ),
            ),
          ),
        );
      }
      // Not a ListView: it would drop the player when scrolled off.
      return SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 48),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _sized(player, maxHeight: height * 0.6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: details,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: upNext,
            ),
          ],
        ),
      );
    },
  );

  /// 16:9, but never taller than [maxHeight].
  Widget _sized(Widget player, {required double maxHeight}) => LayoutBuilder(
    builder: (context, c) {
      var w = c.maxWidth;
      var h = w * 9 / 16;
      if (h > maxHeight && maxHeight > 200) {
        h = maxHeight;
        w = h * 16 / 9;
      }
      return Center(
        child: SizedBox(width: w, height: h, child: player),
      );
    },
  );
}

/// The player, or what stands in for it: a spinner while loading, the
/// processing progress or failure for the owner's unfinished videos.
class _PlayerArea extends StatelessWidget {
  const _PlayerArea({
    super.key,
    required this.state,
    required this.controller,
    required this.fullscreen,
    required this.onToggleFullscreen,
  });

  final VideoDetailState state;
  final PlayerController controller;
  final bool fullscreen;
  final VoidCallback onToggleFullscreen;

  @override
  Widget build(BuildContext context) => switch (state) {
    VideoDetailReady(:final video) when video.isPlayable => PlayerView(
      controller: controller,
      title: video.title,
      posterUrl: video.thumbnailUrl,
      fullscreen: fullscreen,
      onToggleFullscreen: onToggleFullscreen,
    ),
    VideoDetailReady(:final video) => _Placeholder(
      video: video,
      child: const _Message(
        icon: Icons.error_outline,
        text: "This video can't be played: it has no stream yet.",
      ),
    ),
    VideoDetailProcessing(:final video, :final progress) => _Placeholder(
      video: video,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _Message(
            icon: Icons.hourglass_top,
            text: 'Processing. It will play here when ready.',
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: 240,
            child: LinearProgressIndicator(
              value: progress == null ? null : progress.percent / 100,
            ),
          ),
          if (progress != null) ...[
            const SizedBox(height: 8),
            Text('${progress.percent}%'),
          ],
        ],
      ),
    ),
    VideoDetailFailed(:final video) => _Placeholder(
      video: video,
      child: const _Message(
        icon: Icons.error_outline,
        text: "Processing failed. Delete this video and upload it again.",
      ),
    ),
    VideoDetailError(:final error, :final video) => _Placeholder(
      video: video,
      child: _Message(icon: Icons.wifi_off, text: error.message),
    ),
    _ => const ColoredBox(
      color: Colors.black,
      child: Center(child: CircularProgressIndicator()),
    ),
  };
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.video, required this.child});
  final Video? video;
  final Widget child;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black,
    child: Stack(
      fit: StackFit.expand,
      children: [
        if (video != null)
          Opacity(
            opacity: 0.25,
            child: VideoThumbnail(url: video!.thumbnailUrl),
          ),
        Center(child: child),
      ],
    ),
  );
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 40, color: Colors.white),
        const SizedBox(height: 12),
        Text(text, textAlign: TextAlign.center),
      ],
    ),
  );
}

/// Title, "views . date", the actions, then the channel row and the
/// description (mockup: 20px title, #AAAAAA meta, dividers between).
class _Details extends StatelessWidget {
  const _Details({required this.state, required this.cubit});

  final VideoDetailState state;
  final VideoDetailCubit cubit;

  @override
  Widget build(BuildContext context) {
    final video = cubit.video;
    if (video == null) {
      return const Padding(
        padding: EdgeInsets.only(top: 16),
        child: ListTileSkeleton(thumbWidth: 0),
      );
    }
    final me = context.select<SessionCubit, String?>(
      (s) => switch (s.state) {
        SessionAuthenticated(:final user) => user.id,
        _ => null,
      },
    );
    final isOwner = me != null && me == video.creator.id;
    final meta = Theme.of(context).textTheme.bodySmall!.copyWith(fontSize: 14);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        SelectableText(
          video.title,
          style: const TextStyle(fontSize: 20, height: 1.3),
        ),
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: 8,
          spacing: 16,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${formatViewsFull(video.viewsCount)} • '
                  '${formatDate(video.createdAt)}',
                  style: meta,
                ),
                if (isOwner) ...[
                  const SizedBox(width: 12),
                  VisibilityChip(video.effectiveVisibility),
                ],
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Action(
                  icon: Icons.reply,
                  flip: true,
                  label: 'SHARE',
                  onPressed: () => _share(context, video),
                ),
                if (isOwner) ...[
                  _Action(
                    icon: Icons.edit_outlined,
                    label: 'EDIT',
                    onPressed: () => showEditVideoDialog(
                      context,
                      video: video,
                      onSave: cubit.update,
                    ),
                  ),
                  _Action(
                    icon: Icons.delete_outline,
                    label: 'DELETE',
                    onPressed: () => _delete(context, video),
                  ),
                ],
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
        const Divider(),
        const SizedBox(height: 16),
        _ChannelRow(video: video),
        const SizedBox(height: 16),
        const Divider(),
      ],
    );
  }

  Future<void> _share(BuildContext context, Video video) async {
    final link = Uri.base.resolve(Routes.watch(video.id)).toString();
    await Clipboard.setData(ClipboardData(text: link));
    if (context.mounted) showSnack(context, 'Link copied to clipboard');
  }

  Future<void> _delete(BuildContext context, Video video) async {
    if (!await confirmDeleteVideo(context, video.title)) return;
    try {
      await cubit.delete();
    } on ApiException catch (e) {
      if (context.mounted) showSnack(context, e.message);
    }
  }
}

class _Action extends StatelessWidget {
  const _Action({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.flip = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool flip;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: onPressed,
    style: TextButton.styleFrom(foregroundColor: YtColors.textPrimary),
    icon: Transform.flip(flipX: flip, child: Icon(icon, size: 22)),
    label: Text(label, style: const TextStyle(letterSpacing: 0.5)),
  );
}

class _ChannelRow extends StatefulWidget {
  const _ChannelRow({required this.video});
  final Video video;

  @override
  State<_ChannelRow> createState() => _ChannelRowState();
}

class _ChannelRowState extends State<_ChannelRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final creator = widget.video.creator;
    final description = widget.video.description ?? '';
    final channel = Routes.channel(creator.id);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppLink(
          location: channel,
          semanticLabel: creator.name,
          child: Avatar(name: creator.name, seed: creator.id, size: 48),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 4),
              AppLink(
                location: channel,
                child: Text(
                  creator.name,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (creator.createdAt != null)
                Text(
                  formatJoined(creator.createdAt!),
                  style: Theme.of(context).textTheme.bodySmall!
                      .copyWith(fontSize: 12),
                ),
              if (description.isNotEmpty) ...[
                const SizedBox(height: 16),
                SelectableText(
                  description,
                  maxLines: _expanded ? null : 3,
                  style: const TextStyle(fontSize: 14, height: 1.45),
                ),
                if (description.length > 180 ||
                    '\n'.allMatches(description).length > 2)
                  TextButton(
                    onPressed: () => setState(() => _expanded = !_expanded),
                    style: TextButton.styleFrom(
                      foregroundColor: YtColors.textSecondary,
                      padding: EdgeInsets.zero,
                    ),
                    child: Text(_expanded ? 'SHOW LESS' : 'SHOW MORE'),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Up next: other public videos, or more from this video's creator.
class _UpNext extends StatefulWidget {
  const _UpNext({required this.state, required this.currentId});
  final VideoDetailState state;
  final String currentId;

  @override
  State<_UpNext> createState() => _UpNextState();
}

class _UpNextState extends State<_UpNext> {
  bool _fromCreator = false;

  @override
  Widget build(BuildContext context) {
    final video = switch (widget.state) {
      VideoDetailReady(:final video) => video,
      VideoDetailProcessing(:final video) => video,
      VideoDetailFailed(:final video) => video,
      VideoDetailLoading(:final video) => video,
      _ => null,
    };
    final creator = video?.creator;
    final videos = context.read<VideoService>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (creator != null)
          Wrap(
            spacing: 12,
            children: [
              FilterPill(
                label: 'All',
                selected: !_fromCreator,
                onTap: () => setState(() => _fromCreator = false),
              ),
              FilterPill(
                label: 'From ${creator.name}',
                selected: _fromCreator,
                onTap: () => setState(() => _fromCreator = true),
              ),
            ],
          ),
        const SizedBox(height: 12),
        BlocProvider<FeedCubit>(
          key: ValueKey(_fromCreator ? 'creator:${creator?.id}' : 'all'),
          create: (_) =>
              (_fromCreator && creator != null
                    ? ChannelCubit(videos, creator.id, limit: 20)
                    : FeedCubit(videos, limit: 20))
                ..load(),
          child: BlocBuilder<FeedCubit, VideoListState>(
            builder: (context, list) {
              if (list.status == ListStatus.initial ||
                  list.status == ListStatus.loading) {
                return Column(
                  children: [
                    for (var i = 0; i < 6; i++)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: ListTileSkeleton(),
                      ),
                  ],
                );
              }
              final items = [
                for (final v in list.items)
                  if (v.id != widget.currentId) v,
              ];
              if (items.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    list.error?.message ?? 'Nothing else to watch yet.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                );
              }
              return Column(
                children: [
                  for (final v in items)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: VideoListTile(key: ValueKey(v.id), video: v),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Unavailable extends StatelessWidget {
  const _Unavailable();

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.videocam_off_outlined,
          size: 64,
          color: YtColors.textSecondary,
        ),
        const SizedBox(height: 16),
        const Text('Video unavailable', style: TextStyle(fontSize: 20)),
        const SizedBox(height: 8),
        Text(
          "This video doesn't exist, was deleted, or is private.",
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 24),
        OutlinedButton(
          onPressed: () => context.go(Routes.home),
          child: const Text('GO HOME'),
        ),
      ],
    ),
  );
}
