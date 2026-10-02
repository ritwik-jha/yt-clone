import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../core/api_exception.dart';
import '../core/theme.dart';
import '../cubits/feed/feed_state.dart';
import '../cubits/my_videos/my_videos_cubit.dart';
import '../models/video.dart';
import '../services/video_service.dart';
import '../widgets/edit_video_sheet.dart';
import '../widgets/error_view.dart';
import '../widgets/owner_menu.dart';
import '../widgets/video_card.dart';
import 'upload_page.dart';
import 'video_player_page.dart';

class MyVideosPage extends StatelessWidget {
  const MyVideosPage({super.key});

  static Route<void> route() =>
      MaterialPageRoute(builder: (_) => const MyVideosPage());

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (ctx) => MyVideosCubit(ctx.read<VideoService>())
      ..load()
      ..startPolling(),
    child: const _MyVideosView(),
  );
}

class _MyVideosView extends StatefulWidget {
  const _MyVideosView();

  @override
  State<_MyVideosView> createState() => _MyVideosViewState();
}

class _MyVideosViewState extends State<_MyVideosView> {
  final _scroll = ScrollController();
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 900) {
        context.read<MyVideosCubit>().loadMore();
      }
    });
    // The timer pauses while the app is in the background.
    _lifecycle = AppLifecycleListener(
      onStateChange: (s) => context.read<MyVideosCubit>().setPaused(
        s != AppLifecycleState.resumed,
      ),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _open(Video video) async {
    final status = video.effectiveStatus;
    if (status == VideoStatus.failed) {
      await _failedDialog(video);
      return;
    }
    final cubit = context.read<MyVideosCubit>();
    final change = await Navigator.of(context)
        .push(VideoPlayerPage.route(video));
    if (change != null) cubit.applyChange(change);
  }

  Future<void> _failedDialog(Video video) async {
    final cubit = context.read<MyVideosCubit>();
    final delete = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Processing failed'),
        content: const Text(
          "We couldn't process this video. Delete it and upload it again.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Close'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Delete',
              style: TextStyle(color: Color(0xFFFF6E6E)),
            ),
          ),
        ],
      ),
    );
    if (delete == true) await _delete(cubit, video);
  }

  Future<void> _delete(MyVideosCubit cubit, Video video) async {
    try {
      await cubit.deleteVideo(video.id);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Video deleted')));
      }
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _onAction(OwnerAction action, Video video) async {
    final cubit = context.read<MyVideosCubit>();
    switch (action) {
      case OwnerAction.edit:
        await showEditVideoSheet(
          context,
          video: video,
          onSave: (changes) => cubit.updateVideo(video.id, changes),
        );
      case OwnerAction.delete:
        if (await confirmDelete(context) && mounted) {
          await _delete(cubit, video);
        }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('My videos')),
    body: BlocBuilder<MyVideosCubit, VideoListState>(
      builder: (context, state) {
        if (state.status == ListStatus.initial ||
            state.status == ListStatus.loading) {
          return const Center(child: CircularProgressIndicator());
        }
        if (state.status == ListStatus.failure) {
          return ErrorView.fromException(
            state.error!,
            onRetry: () => context.read<MyVideosCubit>().load(),
          );
        }
        if (state.items.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.video_library_outlined,
                  size: 56,
                  color: YtColors.textSecondary,
                ),
                const SizedBox(height: 16),
                const Text("You haven't uploaded anything yet"),
                const SizedBox(height: 16),
                FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                  onPressed: () =>
                      Navigator.of(context).push(UploadPage.route()),
                  child: const Text('Upload a video'),
                ),
              ],
            ),
          );
        }
        return RefreshIndicator(
          color: YtColors.red,
          backgroundColor: YtColors.surfaceHigh,
          onRefresh: () => context.read<MyVideosCubit>().refresh(),
          child: ListView.builder(
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: state.items.length + (state.hasMore ? 1 : 0),
            itemBuilder: (context, i) {
              if (i >= state.items.length) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                );
              }
              final video = state.items[i];
              return VideoCard(
                video: video,
                showOwnerInfo: true,
                progress: state.progress[video.id],
                onTap: () => _open(video),
                trailing: OwnerMenu(
                  canEdit: video.effectiveStatus != VideoStatus.failed,
                  onSelected: (a) => _onAction(a, video),
                ),
              );
            },
          ),
        );
      },
    ),
  );
}
