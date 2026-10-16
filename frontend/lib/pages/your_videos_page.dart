import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../app/routes.dart';
import '../core/api_exception.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../cubits/feed/feed_state.dart';
import '../cubits/my_videos/my_videos_cubit.dart';
import '../cubits/session/session_cubit.dart';
import '../cubits/session/session_state.dart';
import '../cubits/upload_video/upload_video_cubit.dart';
import '../cubits/upload_video/upload_video_state.dart';
import '../models/progress.dart';
import '../models/video.dart';
import '../services/video_service.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/edit_video_dialog.dart';
import '../widgets/error_view.dart';
import '../widgets/link.dart';
import '../widgets/status_chip.dart';
import '../widgets/video_grid.dart';
import '../widgets/video_thumbnail.dart';

/// `/my-videos`: every video the user uploaded, whatever its visibility or
/// status, with transcoding progress polled live and edit / delete.
class YourVideosPage extends StatelessWidget {
  const YourVideosPage({super.key});

  @override
  Widget build(BuildContext context) => BlocBuilder<SessionCubit, SessionState>(
    buildWhen: (a, b) => a.runtimeType != b.runtimeType,
    builder: (context, session) => session is SessionAuthenticated
        ? BlocProvider(
            create: (context) => MyVideosCubit(context.read<VideoService>())
              ..load()
              ..startPolling(),
            child: const _YourVideos(),
          )
        : const Center(child: CircularProgressIndicator()),
  );
}

class _YourVideos extends StatefulWidget {
  const _YourVideos();

  @override
  State<_YourVideos> createState() => _YourVideosState();
}

class _YourVideosState extends State<_YourVideos> {
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(
    // Hidden tab: stop polling progress.
    onHide: () => context.read<MyVideosCubit>().setPaused(true),
    onShow: () => context.read<MyVideosCubit>().setPaused(false),
  );

  @override
  void initState() {
    super.initState();
    _lifecycle;
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      BlocListener<UploadVideoCubit, UploadVideoState>(
        listenWhen: (_, next) => next is UploadVideoSuccess,
        listener: (context, _) => context.read<MyVideosCubit>().refresh(),
        child: LoadMoreListener(
          onNearEnd: () => context.read<MyVideosCubit>().loadMore(),
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Your videos',
                          style: TextStyle(fontSize: 24),
                        ),
                      ),
                      FilledButton.icon(
                        onPressed: () => context.go(Routes.upload),
                        icon: const Icon(Icons.file_upload_outlined),
                        label: const Text('UPLOAD VIDEO'),
                      ),
                    ],
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: _UploadStatus()),
              const SliverToBoxAdapter(child: _TableHeader()),
              const _Rows(),
            ],
          ),
        ),
      );
}

/// The app-wide upload, while it runs or after it failed.
class _UploadStatus extends StatelessWidget {
  const _UploadStatus();

  @override
  Widget build(BuildContext context) =>
      BlocBuilder<UploadVideoCubit, UploadVideoState>(
        builder: (context, state) {
          final draft = context.read<UploadVideoCubit>().draft;
          final text = switch (state) {
            UploadVideoInProgress(:final stage, :final fraction) =>
              '${stage.label}: "${draft?.title}"'
                  '${fraction == null ? '' : ' ${(fraction * 100).round()}%'}',
            UploadVideoError(:final message) =>
              'Upload of "${draft?.title}" failed: $message',
            _ => null,
          };
          if (text == null) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Material(
              color: YtColors.surfaceHigh,
              child: ListTile(
                leading: state is UploadVideoError
                    ? const Icon(Icons.error_outline, color: YtColors.error)
                    : const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                title: Text(text),
                trailing: TextButton(
                  onPressed: () => context.go(Routes.upload),
                  child: const Text('DETAILS'),
                ),
              ),
            ),
          );
        },
      );
}

const _colVisibility = 120.0;
const _colStatus = 140.0;
const _colDate = 120.0;
const _colViews = 80.0;
const _colActions = 96.0;

bool _wide(BuildContext context) => MediaQuery.sizeOf(context).width >= 1100;

class _TableHeader extends StatelessWidget {
  const _TableHeader();

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      color: YtColors.textSecondary,
    );
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: YtColors.divider),
          bottom: BorderSide(color: YtColors.divider),
        ),
      ),
      child: Row(
        children: [
          const Expanded(child: Text('Video', style: style)),
          if (_wide(context)) ...const [
            SizedBox(
              width: _colVisibility,
              child: Text('Visibility', style: style),
            ),
            SizedBox(
              width: _colStatus,
              child: Text('Status', style: style),
            ),
            SizedBox(
              width: _colDate,
              child: Text('Date', style: style),
            ),
            SizedBox(
              width: _colViews,
              child: Text('Views', style: style, textAlign: TextAlign.right),
            ),
          ],
          const SizedBox(width: _colActions),
        ],
      ),
    );
  }
}

class _Rows extends StatelessWidget {
  const _Rows();

  @override
  Widget build(BuildContext context) =>
      BlocBuilder<MyVideosCubit, VideoListState>(
        builder: (context, state) {
          if (state.status == ListStatus.initial ||
              state.status == ListStatus.loading) {
            return const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(48),
                child: Center(child: CircularProgressIndicator()),
              ),
            );
          }
          if (state.status == ListStatus.failure && state.error != null) {
            return SliverFillRemaining(
              hasScrollBody: false,
              child: ErrorView.fromException(
                state.error!,
                onRetry: () => context.read<MyVideosCubit>().load(),
              ),
            );
          }
          if (state.items.isEmpty) {
            return SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const ErrorView(
                      message: "You haven't uploaded any videos yet.",
                      icon: Icons.video_library_outlined,
                    ),
                    FilledButton(
                      onPressed: () => context.go(Routes.upload),
                      child: const Text('UPLOAD VIDEO'),
                    ),
                  ],
                ),
              ),
            );
          }
          return SliverList.builder(
            itemCount: state.items.length,
            itemBuilder: (context, i) {
              final video = state.items[i];
              return _Row(
                key: ValueKey(video.id),
                video: video,
                progress: state.progress[video.id],
              );
            },
          );
        },
      );
}

class _Row extends StatelessWidget {
  const _Row({super.key, required this.video, required this.progress});

  final Video video;
  final Progress? progress;

  Future<void> _delete(BuildContext context) async {
    if (!await confirmDeleteVideo(context, video.title)) return;
    if (!context.mounted) return;
    try {
      await context.read<MyVideosCubit>().deleteVideo(video.id);
      if (context.mounted) showSnack(context, 'Video deleted');
    } on ApiException catch (e) {
      if (context.mounted) showSnack(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = _wide(context);
    final status = video.effectiveStatus;
    final statusCell = Wrap(
      spacing: 0,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        StatusChip(status),
        if (status.isUnfinished && progress != null) ...[
          const SizedBox(width: 6),
          Text(
            '${progress!.percent}%',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
    final small = Theme.of(context).textTheme.bodySmall!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: YtColors.divider)),
      ),
      child: Row(
        children: [
          Expanded(
            child: AppLink(
              location: Routes.watch(video.id),
              semanticLabel: video.title,
              child: Row(
                children: [
                  SizedBox(
                    width: 120,
                    child: VideoThumbnail(
                      url: video.thumbnailUrl,
                      durationSeconds: video.durationSeconds,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          video.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14),
                        ),
                        const SizedBox(height: 4),
                        if (wide)
                          Text(
                            (video.description ?? '').isEmpty
                                ? 'Add description'
                                : video.description!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: small.copyWith(fontSize: 12),
                          )
                        else
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              VisibilityChip(video.effectiveVisibility),
                              statusCell,
                              Text(
                                viewsAndAge(video.viewsCount, video.createdAt),
                                style: small.copyWith(fontSize: 12),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (wide) ...[
            SizedBox(
              width: _colVisibility,
              child: Align(
                alignment: Alignment.centerLeft,
                child: VisibilityChip(video.effectiveVisibility),
              ),
            ),
            SizedBox(width: _colStatus, child: statusCell),
            SizedBox(
              width: _colDate,
              child: Text(formatDate(video.createdAt), style: small),
            ),
            SizedBox(
              width: _colViews,
              child: Text(
                '${video.viewsCount}',
                style: small,
                textAlign: TextAlign.right,
              ),
            ),
          ],
          SizedBox(
            width: _colActions,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: 'Edit',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => showEditVideoDialog(
                    context,
                    video: video,
                    onSave: (changes) => context
                        .read<MyVideosCubit>()
                        .updateVideo(video.id, changes),
                  ),
                ),
                IconButton(
                  tooltip: 'Delete',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _delete(context),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
