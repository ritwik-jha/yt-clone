import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../core/server_settings.dart';
import '../core/theme.dart';
import '../widgets/brand_mark.dart';
import '../core/token_store.dart';
import '../cubits/pending_uploads/pending_uploads_cubit.dart';
import '../cubits/feed/feed_cubit.dart';
import '../cubits/feed/feed_state.dart';
import '../cubits/session/session_cubit.dart';
import '../cubits/session/session_state.dart';
import '../models/video.dart';
import '../services/upload_job_store.dart';
import '../services/upload_video_service.dart';
import '../services/video_service.dart';
import '../widgets/pending_uploads_banner.dart';
import '../widgets/server_url_dialog.dart';
import '../widgets/video_skeleton.dart';
import '../widgets/error_view.dart';
import '../widgets/video_card.dart';
import 'my_videos_page.dart';
import 'upload_page.dart';
import 'video_player_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) => MultiBlocProvider(
    providers: [
      BlocProvider(
        create: (ctx) => FeedCubit(ctx.read<VideoService>())..load(),
      ),
      // Saves uploads that finished but were never saved, and surfaces any
      // other unfinished ones as a banner.
      BlocProvider(
        create: (ctx) => PendingUploadsCubit(
          ctx.read<UploadJobStore>(),
          ctx.read<UploadVideoService>(),
        )..load(),
      ),
    ],
    child: const _HomeView(),
  );
}

class _HomeView extends StatefulWidget {
  const _HomeView();

  @override
  State<_HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<_HomeView> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  // Fetch the next page once the list is within ~3 cards of its end.
  void _onScroll() {
    if (_scroll.position.extentAfter < 3 * 320) {
      context.read<FeedCubit>().loadMore();
    }
  }

  Future<void> _openVideo(Video video) async {
    final change = await Navigator.of(context)
        .push(VideoPlayerPage.route(video));
    if (!mounted) return;
    final feed = context.read<FeedCubit>();
    switch (change) {
      case VideoDeleted(:final id):
        feed.remove(id);
      case VideoUpdated(:final video):
        if (video.effectiveVisibility != VideoVisibility.public) {
          feed.remove(video.id);
        } else {
          feed.replace(video);
        }
      case null:
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = context.select<SessionCubit, String>(
      (c) => switch (c.state) {
        SessionAuthenticated(:final user) => user.name,
        _ => '',
      },
    );
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        title: Row(
          children: [
            const BrandMark(size: 28),
            const SizedBox(width: 6),
            const Text(
              'Video Stream',
              style: TextStyle(fontSize: 19, letterSpacing: -0.5),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Upload',
            icon: const Icon(Icons.add_circle_outline, size: 28),
            onPressed: () => Navigator.of(context).push(UploadPage.route()),
          ),
          PopupMenuButton<String>(
            tooltip: 'Account',
            offset: const Offset(0, 48),
            onSelected: (v) {
              if (v == 'mine') {
                Navigator.of(context).push(MyVideosPage.route());
              } else if (v == 'logout') {
                context.read<SessionCubit>().logout();
              } else if (v == 'server') {
                showServerUrlDialog(context, context.read<ServerSettings>());
              } else if (v == 'expire') {
                _expireAccessToken(context);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                enabled: false,
                child: Text(
                  user,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'mine',
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.video_library_outlined),
                  title: Text('My videos'),
                ),
              ),
              const PopupMenuItem(
                value: 'logout',
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.logout),
                  title: Text('Log out'),
                ),
              ),
              if (context.read<ServerSettings>().canChange)
                const PopupMenuItem(
                  value: 'server',
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.dns_outlined),
                    title: Text('Backend server'),
                  ),
                ),
              if (kDebugMode)
                const PopupMenuItem(
                  value: 'expire',
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.timer_off_outlined),
                    title: Text('Expire access token'),
                  ),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: CircleAvatar(
                radius: 15,
                backgroundColor: YtColors.blue,
                child: Text(
                  user.isEmpty ? '?' : user[0].toUpperCase(),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Colors.black,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      body: BlocConsumer<FeedCubit, VideoListState>(
        listenWhen: (p, n) =>
            n.error != null && n.items.isNotEmpty && p.error != n.error,
        listener: (context, state) =>
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(state.error!.message))),
        builder: (context, state) {
          if (state.status == ListStatus.initial ||
              state.status == ListStatus.loading) {
            return const VideoListSkeleton();
          }
          if (state.status == ListStatus.failure) {
            return ErrorView.fromException(
              state.error!,
              onRetry: () => context.read<FeedCubit>().load(),
            );
          }
          if (state.items.isEmpty) {
            return RefreshIndicator(
              onRefresh: () => context.read<FeedCubit>().refresh(),
              child: ListView(
                children: [
                  SizedBox(
                    height: MediaQuery.of(context).size.height * 0.6,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.video_library_outlined,
                            size: 56,
                            color: YtColors.textSecondary,
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'No videos yet',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 16),
                          FilledButton.icon(
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(0, 44),
                            ),
                            onPressed: () =>
                                Navigator.of(context).push(UploadPage.route()),
                            icon: const Icon(Icons.upload),
                            label: const Text('Upload'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          }
          return RefreshIndicator(
            color: YtColors.red,
            backgroundColor: YtColors.surfaceHigh,
            onRefresh: () => context.read<FeedCubit>().refresh(),
            child: ListView.builder(
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount:
                  1 +
                  state.items.length +
                  (state.status == ListStatus.loadingMore ? 1 : 0),
              itemBuilder: (context, i) {
                if (i == 0) return const PendingUploadsBanner();
                i -= 1;
                if (i >= state.items.length) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  );
                }
                final video = state.items[i];
                return VideoCard(video: video, onTap: () => _openVideo(video));
              },
            ),
          );
        },
      ),
    );
  }
}

/// Debug only: corrupts the stored access token so the next request gets a
/// 401 and exercises the refresh path (PLAN §12).
Future<void> _expireAccessToken(BuildContext context) async {
  final feed = context.read<FeedCubit>();
  final messenger = ScaffoldMessenger.of(context);
  await context.read<TokenStore>().save(
    accessTokenKey,
    'expired.invalid.token',
  );
  messenger.showSnackBar(
    const SnackBar(content: Text('Access token expired. Refreshing the feed…')),
  );
  await feed.refresh();
}
