import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../core/theme.dart';
import '../cubits/feed/feed_cubit.dart';
import '../cubits/feed/feed_state.dart';
import '../cubits/session/session_cubit.dart';
import '../cubits/session/session_state.dart';
import '../models/video.dart';
import '../services/video_service.dart';
import '../widgets/error_view.dart';
import '../widgets/video_card.dart';
import 'my_videos_page.dart';
import 'upload_page.dart';
import 'video_player_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (ctx) => FeedCubit(ctx.read<VideoService>())..load(),
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
            Container(
              width: 32,
              height: 22,
              decoration: BoxDecoration(
                color: YtColors.red,
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Icon(
                Icons.play_arrow_rounded,
                size: 18,
                color: Colors.white,
              ),
            ),
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
            return const Center(child: CircularProgressIndicator());
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
                  state.items.length +
                  (state.status == ListStatus.loadingMore ? 1 : 0),
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
                return VideoCard(video: video, onTap: () => _openVideo(video));
              },
            ),
          );
        },
      ),
    );
  }
}
