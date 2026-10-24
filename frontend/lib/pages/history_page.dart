import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../core/format.dart';
import '../core/theme.dart';
import '../cubits/feed/feed_state.dart';
import '../cubits/history/history_cubit.dart';
import '../cubits/history/history_state.dart';
import '../cubits/session/session_cubit.dart';
import '../cubits/session/session_state.dart';
import '../models/watch_progress.dart';
import '../services/history_sync.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/error_view.dart';
import '../widgets/skeletons.dart';
import '../widgets/video_grid.dart';
import '../widgets/video_list_tile.dart';

/// `/feed/history`: what the signed-in user watched, newest first, grouped
/// by day, with a progress bar on each thumbnail. Each row can be removed
/// (with undo); *Clear all watch history* empties it.
class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) => BlocBuilder<SessionCubit, SessionState>(
    buildWhen: (a, b) => a.runtimeType != b.runtimeType,
    builder: (context, session) => session is SessionAuthenticated
        ? BlocProvider(
            create: (context) =>
                HistoryCubit(context.read<HistorySync>())..load(),
            child: const _History(),
          )
        : const Center(child: CircularProgressIndicator()),
  );
}

/// The list and the side column sit side by side from this width.
const _twoColumns = 1100.0;

class _History extends StatelessWidget {
  const _History();

  @override
  Widget build(BuildContext context) =>
      BlocListener<HistoryCubit, HistoryState>(
        listenWhen: (a, b) => b.notice != null && a.notice != b.notice,
        listener: (context, state) => showSnack(context, state.notice!.message),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= _twoColumns;
            final list = LoadMoreListener(
              onNearEnd: () => context.read<HistoryCubit>().loadMore(),
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Watch history',
                            style: TextStyle(fontSize: 24),
                          ),
                          if (!wide) ...[
                            const SizedBox(height: 8),
                            const _ClearAllButton(),
                          ],
                        ],
                      ),
                    ),
                  ),
                  _Rows(large: wide),
                ],
              ),
            );
            if (!wide) return list;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1000),
                      child: list,
                    ),
                  ),
                ),
                const SizedBox(
                  width: 320,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(24, 88, 24, 24),
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: _ClearAllButton(),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      );
}

class _Rows extends StatelessWidget {
  const _Rows({required this.large});
  final bool large;

  @override
  Widget build(BuildContext context) => BlocBuilder<HistoryCubit, HistoryState>(
    builder: (context, state) {
      if (state.unavailable) {
        return const SliverFillRemaining(
          hasScrollBody: false,
          child: ErrorView(
            message: "Watch history isn't available on this server.",
            icon: Icons.history,
          ),
        );
      }
      if (state.status == ListStatus.initial ||
          state.status == ListStatus.loading) {
        return SliverList.list(
          children: [
            for (var i = 0; i < 4; i++)
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 8, 24, 8),
                child: ListTileSkeleton(),
              ),
          ],
        );
      }
      if (state.status == ListStatus.failure && state.error != null) {
        return SliverFillRemaining(
          hasScrollBody: false,
          child: ErrorView.fromException(
            state.error!,
            onRetry: () => context.read<HistoryCubit>().load(),
          ),
        );
      }
      if (state.items.isEmpty) {
        return const SliverFillRemaining(
          hasScrollBody: false,
          child: ErrorView(
            message: 'Videos you watch will show up here.',
            icon: Icons.history,
          ),
        );
      }
      final days = groupByDay(state.items);
      return SliverList.list(
        children: [
          for (final day in days) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
              child: Text(
                day.label,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            for (final entry in day.entries)
              Padding(
                key: ValueKey(entry.video.id),
                padding: const EdgeInsets.fromLTRB(24, 0, 8, 16),
                child: _Row(entry: entry, large: large),
              ),
          ],
          if (state.status == ListStatus.loadingMore)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      );
    },
  );
}

class _Row extends StatelessWidget {
  const _Row({required this.entry, required this.large});
  final HistoryEntry entry;
  final bool large;

  @override
  Widget build(BuildContext context) => VideoListTile(
    video: entry.video,
    large: large,
    meta: 'Watched ${timeAgo(entry.progress.lastWatchedAt)}',
    trailing: IconButton(
      tooltip: 'Remove from watch history',
      icon: const Icon(Icons.close, color: YtColors.textSecondary),
      onPressed: () => _remove(context),
    ),
  );

  void _remove(BuildContext context) {
    final cubit = context.read<HistoryCubit>();
    final id = entry.video.id;
    cubit.remove(id);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Removed from watch history'),
          duration: cubit.undoWindow - const Duration(milliseconds: 500),
          action: SnackBarAction(
            label: 'UNDO',
            onPressed: () => cubit.undo(id),
          ),
        ),
      );
  }
}

class _ClearAllButton extends StatelessWidget {
  const _ClearAllButton();

  @override
  Widget build(BuildContext context) => BlocBuilder<HistoryCubit, HistoryState>(
    buildWhen: (a, b) =>
        a.items.isEmpty != b.items.isEmpty || a.unavailable != b.unavailable,
    builder: (context, state) => TextButton.icon(
      onPressed: state.items.isEmpty || state.unavailable
          ? null
          : () => _clear(context),
      style: TextButton.styleFrom(foregroundColor: YtColors.textPrimary),
      icon: const Icon(Icons.delete_outline),
      label: const Text('Clear all watch history'),
    ),
  );

  Future<void> _clear(BuildContext context) async {
    final cubit = context.read<HistoryCubit>();
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Clear watch history?'),
            content: const Text(
              'Your watch history will be cleared on every browser where '
              "you're signed in, and videos will no longer resume.",
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('CANCEL'),
              ),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: YtColors.error),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('CLEAR WATCH HISTORY'),
              ),
            ],
          ),
        ) ??
        false;
    if (ok) await cubit.clear();
  }
}
