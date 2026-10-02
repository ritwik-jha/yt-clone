import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../core/api_exception.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../cubits/session/session_cubit.dart';
import '../cubits/video_detail/video_detail_cubit.dart';
import '../cubits/video_detail/video_detail_state.dart';
import '../models/video.dart';
import '../services/video_service.dart';
import '../widgets/edit_video_sheet.dart';
import '../widgets/error_view.dart';
import '../widgets/owner_menu.dart';
import '../widgets/status_chip.dart';

/// Pops with a [VideoChange] when the owner edited or deleted the video.
class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({super.key, required this.video});

  final Video video;

  static Route<VideoChange?> route(Video video) => MaterialPageRoute(
    builder: (ctx) => BlocProvider(
      create: (_) =>
          VideoDetailCubit(ctx.read<VideoService>(), initial: video)
            ..load(video.id),
      child: VideoPlayerPage(video: video),
    ),
  );

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  BetterPlayerController? _player;
  String? _playerUrl;
  double _aspectRatio = 16 / 9; // placeholder until the video reports its own
  bool _descriptionExpanded = false;
  VideoChange? _change;

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  void _ensurePlayer(Video video) {
    final url = video.playbackUrl;
    if (url == null || url == _playerUrl) return;
    _player?.dispose();
    _playerUrl = url;
    final isIos = defaultTargetPlatform == TargetPlatform.iOS;
    final controller = BetterPlayerController(
      const BetterPlayerConfiguration(
        aspectRatio: 16 / 9,
        fit: BoxFit.contain,
        autoPlay: true,
        autoDetectFullscreenAspectRatio: true,
        autoDetectFullscreenDeviceOrientation: true,
        controlsConfiguration: BetterPlayerControlsConfiguration(
          enableQualities: true,
          enablePlaybackSpeed: true,
          enableFullscreen: true,
          enableSubtitles: false,
          enableAudioTracks: false,
          progressBarPlayedColor: YtColors.red,
          progressBarHandleColor: YtColors.red,
          overflowModalColor: YtColors.surfaceHigh,
          overflowModalTextColor: Colors.white,
          overflowMenuIconsColor: Colors.white,
        ),
      ),
      betterPlayerDataSource: BetterPlayerDataSource(
        BetterPlayerDataSourceType.network,
        url,
        videoFormat: isIos
            ? BetterPlayerVideoFormat.hls
            : BetterPlayerVideoFormat.dash,
      ),
    );
    var counted = false;
    controller.addEventsListener((event) {
      switch (event.betterPlayerEventType) {
        case BetterPlayerEventType.initialized:
          final ratio = controller.videoPlayerController?.value.aspectRatio;
          if (ratio != null && ratio > 0 && mounted) {
            setState(() => _aspectRatio = ratio); // plan D17
          }
        case BetterPlayerEventType.play when !counted:
          counted = true;
          if (mounted) {
            context.read<VideoDetailCubit>().recordView(); // plan D18
          }
        default:
      }
    });
    _player = controller;
  }

  Future<void> _onOwnerAction(OwnerAction action, Video video) async {
    final cubit = context.read<VideoDetailCubit>();
    switch (action) {
      case OwnerAction.edit:
        await showEditVideoSheet(context, video: video, onSave: cubit.update);
      case OwnerAction.delete:
        if (!await confirmDelete(context) || !mounted) return;
        await _player?.pause();
        try {
          await cubit.delete();
        } on ApiException catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(e.message)));
          }
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = context.read<SessionCubit>().user;
    return BlocConsumer<VideoDetailCubit, VideoDetailState>(
      listener: (context, state) {
        if (state is VideoDetailDeleted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Video deleted')));
          Navigator.of(context).pop(VideoDeleted(state.id));
        }
      },
      builder: (context, state) {
        final video = context.read<VideoDetailCubit>().video ?? widget.video;
        if (state is VideoDetailReady) {
          _change = VideoUpdated(state.video);
        }
        final isOwner = me != null && video.creator.id == me.id;
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) Navigator.of(context).pop(_change);
          },
          child: Scaffold(
            appBar: AppBar(
              actions: [
                if (isOwner && state is! VideoDetailNotFound)
                  OwnerMenu(
                    canEdit: state is! VideoDetailFailed,
                    onSelected: (a) => _onOwnerAction(a, video),
                  ),
              ],
            ),
            body: SafeArea(child: _body(context, state, video, isOwner)),
          ),
        );
      },
    );
  }

  Widget _body(
    BuildContext context,
    VideoDetailState state,
    Video video,
    bool isOwner,
  ) {
    switch (state) {
      case VideoDetailNotFound():
        return const ErrorView(
          message: "This video isn't available",
          icon: Icons.video_library_outlined,
        );
      case VideoDetailError(:final error) when state.video == null:
        return ErrorView.fromException(
          error,
          onRetry: () => context.read<VideoDetailCubit>().load(widget.video.id),
        );
      default:
    }

    final maxHeight = MediaQuery.of(context).size.height * 0.6;
    Widget player;
    switch (state) {
      case VideoDetailReady(:final video):
        if (video.isPlayable) {
          _ensurePlayer(video);
          player = BetterPlayer(controller: _player!);
        } else {
          player = _PlayerMessage(
            thumbnail: video.thumbnailUrl,
            icon: Icons.phone_iphone,
            text: "This video can't play on iPhone yet",
          );
        }
      case VideoDetailProcessing(:final progress):
        player = _PlayerMessage(
          thumbnail: video.thumbnailUrl,
          progress: (progress?.percent ?? 0) / 100,
          text: switch (progress?.percent ?? 0) {
            0 => 'Waiting to process…',
            final p when p < 25 => 'Preparing video… $p%',
            final p when p < 80 => 'Transcoding… $p%',
            final p => 'Finishing up… $p%',
          },
        );
      case VideoDetailFailed():
        player = _PlayerMessage(
          thumbnail: video.thumbnailUrl,
          icon: Icons.error_outline,
          text: 'Processing failed',
        );
      default:
        player = const ColoredBox(
          color: Colors.black,
          child: Center(child: CircularProgressIndicator()),
        );
    }

    final aspect = state is VideoDetailReady && video.isPlayable
        ? _aspectRatio
        : 16 / 9;

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: Center(
            child: AspectRatio(aspectRatio: aspect, child: player),
          ),
        ),
        _Details(
          video: video,
          isOwner: isOwner,
          expanded: _descriptionExpanded,
          onToggle: () =>
              setState(() => _descriptionExpanded = !_descriptionExpanded),
        ),
      ],
    );
  }
}

class _PlayerMessage extends StatelessWidget {
  const _PlayerMessage({
    required this.thumbnail,
    required this.text,
    this.icon,
    this.progress,
  });

  final String thumbnail;
  final String text;
  final IconData? icon;
  final double? progress;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      Image.network(
        thumbnail,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) =>
            const ColoredBox(color: YtColors.surfaceHigh),
      ),
      const ColoredBox(color: Color(0xBB000000)),
      Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) Icon(icon, size: 36),
            if (icon != null) const SizedBox(height: 8),
            Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
            if (progress != null) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: 180,
                child: LinearProgressIndicator(
                  value: progress == 0 ? null : progress,
                ),
              ),
            ],
          ],
        ),
      ),
    ],
  );
}

class _Details extends StatelessWidget {
  const _Details({
    required this.video,
    required this.isOwner,
    required this.expanded,
    required this.onToggle,
  });

  final Video video;
  final bool isOwner;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final description = video.description;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            video.title,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '${formatViewsFull(video.viewsCount)} · ${timeAgo(video.createdAt)}',
                style: const TextStyle(
                  color: YtColors.textSecondary,
                  fontSize: 13,
                ),
              ),
              if (isOwner) VisibilityChip(video.effectiveVisibility),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: YtColors.surfaceHigh,
                child: Text(
                  video.creator.name.isEmpty
                      ? '?'
                      : video.creator.name[0].toUpperCase(),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      video.creator.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    if (video.creator.createdAt != null)
                      Text(
                        formatJoined(video.creator.createdAt!),
                        style: const TextStyle(
                          color: YtColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (description != null && description.isNotEmpty) ...[
            const SizedBox(height: 14),
            InkWell(
              onTap: onToggle,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: YtColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  description,
                  maxLines: expanded ? null : 3,
                  overflow: expanded
                      ? TextOverflow.visible
                      : TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5, height: 1.4),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
