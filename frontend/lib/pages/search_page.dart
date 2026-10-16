import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../cubits/feed/feed_cubit.dart';
import '../cubits/feed/feed_state.dart';
import '../services/video_service.dart';
import '../widgets/chip_bar.dart';
import '../widgets/error_view.dart';
import '../widgets/skeletons.dart';
import '../widgets/video_grid.dart';
import '../widgets/video_list_tile.dart';

/// `/results?search_query=...`: matching public videos as large rows,
/// newest or most viewed first.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.query});

  final String query;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  VideoSort _sort = VideoSort.latest;

  @override
  Widget build(BuildContext context) {
    if (widget.query.trim().isEmpty) {
      return const ErrorView(
        message: 'Type something in the search box to find videos.',
        icon: Icons.search,
      );
    }
    return BlocProvider(
      key: ValueKey(_sort),
      create: (context) => FeedCubit.search(
        context.read<VideoService>(),
        widget.query,
        sort: _sort,
      )..load(),
      child: Builder(
        builder: (context) => LoadMoreListener(
          onNearEnd: () => context.read<FeedCubit>().loadMore(),
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1096),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Row(
                        children: [
                          Expanded(
                            child: ChipBar<VideoSort>(
                              padding: EdgeInsets.zero,
                              options: const [
                                ChipOption(VideoSort.latest, 'Newest'),
                                ChipOption(VideoSort.popular, 'Most viewed'),
                              ],
                              selected: _sort,
                              onSelected: (s) => setState(() => _sort = s),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: Divider()),
              _Results(query: widget.query),
            ],
          ),
        ),
      ),
    );
  }
}

class _Results extends StatelessWidget {
  const _Results({required this.query});
  final String query;

  static Widget _centered(Widget child) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1096),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: child,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => BlocBuilder<FeedCubit, VideoListState>(
    builder: (context, state) {
      final large = MediaQuery.sizeOf(context).width >= 720;
      if (state.status == ListStatus.initial ||
          state.status == ListStatus.loading) {
        return SliverList.list(
          children: [
            for (var i = 0; i < 4; i++)
              _centered(ListTileSkeleton(thumbWidth: large ? 360 : 168)),
          ],
        );
      }
      if (state.status == ListStatus.failure && state.error != null) {
        return SliverFillRemaining(
          hasScrollBody: false,
          child: ErrorView.fromException(
            state.error!,
            onRetry: () => context.read<FeedCubit>().load(),
          ),
        );
      }
      if (state.items.isEmpty) {
        return SliverFillRemaining(
          hasScrollBody: false,
          child: ErrorView(
            message: 'No results for "$query".\nTry different keywords.',
            icon: Icons.search_off,
          ),
        );
      }
      return SliverList.builder(
        itemCount: state.items.length + (state.hasMore ? 1 : 0),
        itemBuilder: (context, i) {
          if (i == state.items.length) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final video = state.items[i];
          return _centered(
            VideoListTile(key: ValueKey(video.id), video: video, large: large),
          );
        },
      );
    },
  );
}
