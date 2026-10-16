import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/theme.dart';
import '../../cubits/session/session_cubit.dart';
import '../../cubits/session/session_state.dart';
import '../../platform/browser.dart';
import '../../widgets/auth_scaffold.dart';
import 'masthead.dart';
import 'sidebar.dart';

enum _Guide { full, mini, none }

/// Masthead + guide around every browse page.
///
/// Like the mockups: the full 240px guide on wide screens (the menu button
/// collapses it to the 72px rail), the rail on medium ones, and a drawer on
/// narrow screens and on the watch page, where the player gets the width.
/// In fullscreen only the page is shown.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final _scaffold = GlobalKey<ScaffoldState>();
  bool _collapsed = false;

  _Guide _guide(double width, String path) {
    if (path == Routes.watchPath || width < YtSizes.rail) return _Guide.none;
    if (width < YtSizes.wide) return _Guide.mini;
    return _collapsed ? _Guide.mini : _Guide.full;
  }

  void _onMenu(double width, String path) {
    if (path == Routes.watchPath || width < YtSizes.wide) {
      _scaffold.currentState?.openDrawer();
    } else {
      setState(() => _collapsed = !_collapsed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final path = GoRouterState.of(context).uri.path;
    final guide = _guide(width, path);
    return BlocListener<SessionCubit, SessionState>(
      listenWhen: (prev, next) =>
          next is SessionUnauthenticated && next.message != null,
      listener: (context, state) =>
          showSnack(context, (state as SessionUnauthenticated).message!),
      child: ValueListenableBuilder<bool>(
        valueListenable: context.read<Browser>().fullscreen,
        builder: (context, fullscreen, _) => Scaffold(
          key: _scaffold,
          drawer: const Drawer(child: Sidebar(inDrawer: true)),
          body: Column(
            children: [
              Visibility(
                visible: !fullscreen,
                maintainState: true,
                child: Masthead(onMenu: () => _onMenu(width, path)),
              ),
              if (!fullscreen) const _SessionBanner(),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!fullscreen && guide == _Guide.full) const Sidebar(),
                    if (!fullscreen && guide == _Guide.mini)
                      const MiniSidebar(),
                    // Its own semantics container: each page route carries a
                    // ModalBarrier whose BlockSemantics would otherwise hide
                    // the masthead and guide from screen readers.
                    Expanded(
                      child: Semantics(container: true, child: widget.child),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Can't reach the server" with a retry, when restoring the session failed
/// for a reason other than being signed out.
class _SessionBanner extends StatelessWidget {
  const _SessionBanner();

  @override
  Widget build(BuildContext context) => BlocBuilder<SessionCubit, SessionState>(
    builder: (context, state) => switch (state) {
      SessionUnavailable(:final message) => MaterialBanner(
        backgroundColor: YtColors.surfaceHigh,
        leading: const Icon(Icons.cloud_off, color: YtColors.warning),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => context.read<SessionCubit>().restore(),
            child: const Text('RETRY'),
          ),
        ],
      ),
      _ => const SizedBox.shrink(),
    },
  );
}
