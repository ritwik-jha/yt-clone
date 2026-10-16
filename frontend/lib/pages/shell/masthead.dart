import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/theme.dart';
import '../../cubits/session/session_cubit.dart';
import '../../cubits/session/session_state.dart';
import '../../cubits/upload_video/upload_video_cubit.dart';
import '../../cubits/upload_video/upload_video_state.dart';
import '../../widgets/avatar.dart';
import '../../widgets/brand_logo.dart';

/// The top bar: menu, logo, search, and the account controls (mockup:
/// 56px, #212121).
class Masthead extends StatelessWidget {
  const Masthead({super.key, required this.onMenu});

  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 656;
    return Container(
      height: YtSizes.mastheadHeight,
      color: YtColors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Menu',
            icon: const Icon(Icons.menu),
            onPressed: onMenu,
          ),
          const SizedBox(width: 8),
          Semantics(
            link: true,
            label: 'Video Stream home',
            excludeSemantics: true,
            child: InkWell(
              onTap: () => context.go(Routes.home),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                child: BrandLogo(showName: !narrow),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: const SearchBox(),
              ),
            ),
          ),
          const SizedBox(width: 16),
          const _AccountArea(),
        ],
      ),
    );
  }
}

/// The search field and button. Shows the current query on the results
/// page; Enter or the button opens `/results?search_query=`.
class SearchBox extends StatefulWidget {
  const SearchBox({super.key});

  @override
  State<SearchBox> createState() => _SearchBoxState();
}

class _SearchBoxState extends State<SearchBox> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  String? _shownQuery;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final uri = GoRouterState.of(context).uri;
    final query = uri.path == Routes.results
        ? uri.queryParameters['search_query'] ?? ''
        : '';
    if (query != _shownQuery) {
      _shownQuery = query;
      _controller.text = query;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit() {
    final query = _controller.text.trim();
    if (query.isEmpty) return;
    _focus.unfocus();
    context.go(Routes.search(query));
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 40,
    child: Row(
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            focusNode: _focus,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _submit(),
            style: const TextStyle(fontSize: 16),
            decoration: InputDecoration(
              hintText: 'Search',
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              border: _border,
              enabledBorder: _border,
              focusedBorder: _border.copyWith(
                borderSide: const BorderSide(color: YtColors.blue),
              ),
              suffixIcon: ListenableBuilder(
                listenable: _controller,
                builder: (context, _) => _controller.text.isEmpty
                    ? const SizedBox.shrink()
                    : IconButton(
                        tooltip: 'Clear search',
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () {
                          _controller.clear();
                          _focus.requestFocus();
                        },
                      ),
              ),
            ),
          ),
        ),
        Tooltip(
          message: 'Search',
          child: Material(
            color: YtColors.surfaceHigh,
            shape: const RoundedRectangleBorder(
              side: BorderSide(color: YtColors.surfaceHigh),
              borderRadius: BorderRadius.horizontal(right: Radius.circular(2)),
            ),
            child: InkWell(
              onTap: _submit,
              child: const SizedBox(
                width: 64,
                height: 40,
                child: Icon(Icons.search, size: 22),
              ),
            ),
          ),
        ),
      ],
    ),
  );

  static const _border = OutlineInputBorder(
    borderRadius: BorderRadius.horizontal(left: Radius.circular(2)),
    borderSide: BorderSide(color: YtColors.surfaceHigh),
  );
}

class _AccountArea extends StatelessWidget {
  const _AccountArea();

  @override
  Widget build(BuildContext context) => BlocBuilder<SessionCubit, SessionState>(
    builder: (context, state) => switch (state) {
      SessionAuthenticated(:final user) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _CreateButton(),
          const SizedBox(width: 8),
          _AccountMenu(name: user.name, email: user.email, id: user.id),
        ],
      ),
      SessionUnauthenticated() || SessionUnavailable() => const SignInButton(),
      SessionUnknown() => const SizedBox(width: 40),
    },
  );
}

/// "SIGN IN" with the account icon, back to this page afterwards.
class SignInButton extends StatelessWidget {
  const SignInButton({super.key});

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: () => context.go(
      Routes.signInPage(next: GoRouterState.of(context).uri.toString()),
    ),
    icon: const Icon(Icons.account_circle_outlined, size: 24),
    label: const Text('SIGN IN'),
    style: OutlinedButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    ),
  );
}

/// The upload ("Create") button; a ring shows progress while an upload runs.
class _CreateButton extends StatelessWidget {
  const _CreateButton();

  @override
  Widget build(BuildContext context) =>
      BlocBuilder<UploadVideoCubit, UploadVideoState>(
        builder: (context, state) {
          final running = state is UploadVideoInProgress ? state : null;
          final failed = state is UploadVideoError;
          return Stack(
            alignment: Alignment.center,
            children: [
              IconButton(
                tooltip: running != null
                    ? '${running.stage.label}…'
                    : failed
                    ? 'Upload failed'
                    : 'Upload video',
                icon: Icon(
                  failed ? Icons.error_outline : Icons.video_call_outlined,
                  color: failed ? YtColors.error : null,
                ),
                onPressed: () => context.go(Routes.upload),
              ),
              if (running != null)
                IgnorePointer(
                  child: SizedBox(
                    width: 36,
                    height: 36,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      value: running.fraction,
                    ),
                  ),
                ),
            ],
          );
        },
      );
}

enum _AccountAction { channel, videos, upload, signOut }

class _AccountMenu extends StatelessWidget {
  const _AccountMenu({
    required this.name,
    required this.email,
    required this.id,
  });

  final String name;
  final String email;
  final String id;

  @override
  Widget build(BuildContext context) => PopupMenuButton<_AccountAction>(
    tooltip: 'Account',
    offset: const Offset(0, 48),
    constraints: const BoxConstraints(minWidth: 280),
    onSelected: (action) {
      switch (action) {
        case _AccountAction.channel:
          context.go(Routes.channel(id));
        case _AccountAction.videos:
          context.go(Routes.myVideos);
        case _AccountAction.upload:
          context.go(Routes.upload);
        case _AccountAction.signOut:
          context.read<SessionCubit>().logout();
      }
    },
    itemBuilder: (context) => [
      PopupMenuItem(
        enabled: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Avatar(name: name, seed: id, size: 40),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        color: YtColors.textPrimary,
                      ),
                    ),
                    Text(
                      email,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        color: YtColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      const PopupMenuDivider(),
      _item(_AccountAction.channel, Icons.account_box_outlined, 'Your channel'),
      _item(_AccountAction.videos, Icons.smart_display_outlined, 'Your videos'),
      _item(_AccountAction.upload, Icons.file_upload_outlined, 'Upload video'),
      const PopupMenuDivider(),
      _item(_AccountAction.signOut, Icons.logout, 'Sign out'),
    ],
    child: Padding(
      padding: const EdgeInsets.all(4),
      child: Avatar(name: name, seed: id, size: 32),
    ),
  );

  PopupMenuItem<_AccountAction> _item(
    _AccountAction action,
    IconData icon,
    String label,
  ) => PopupMenuItem(
    value: action,
    child: Row(
      children: [Icon(icon, size: 24), const SizedBox(width: 16), Text(label)],
    ),
  );
}
