import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../core/theme.dart';
import '../../cubits/session/session_cubit.dart';
import '../../cubits/session/session_state.dart';
import '../../widgets/brand_logo.dart';
import 'masthead.dart';

class _NavItem {
  const _NavItem(this.icon, this.selectedIcon, this.label, this.location);
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final String location;
}

List<_NavItem> _primary(SessionState session) => [
  const _NavItem(Icons.home_outlined, Icons.home, 'Home', Routes.home),
  if (session case SessionAuthenticated(:final user)) ...[
    _NavItem(
      Icons.account_box_outlined,
      Icons.account_box,
      'Your channel',
      Routes.channel(user.id),
    ),
    const _NavItem(
      Icons.smart_display_outlined,
      Icons.smart_display,
      'Your videos',
      Routes.myVideos,
    ),
    const _NavItem(
      Icons.file_upload_outlined,
      Icons.file_upload,
      'Upload',
      Routes.upload,
    ),
  ],
];

bool _isSelected(_NavItem item, Uri uri) => item.location == Routes.home
    ? uri.path == Routes.home
    : uri.path == item.location || uri.path.startsWith('${item.location}/');

/// The full guide (mockup: 240px, #212121): icon + label rows, 40px tall,
/// the selected one highlighted #303030.
class Sidebar extends StatelessWidget {
  const Sidebar({super.key, this.inDrawer = false});

  /// In the drawer it also carries the menu button and logo, like the
  /// masthead it covers.
  final bool inDrawer;

  @override
  Widget build(BuildContext context) {
    final uri = GoRouterState.of(context).uri;
    return BlocBuilder<SessionCubit, SessionState>(
      builder: (context, session) => Container(
        width: YtSizes.sidebarWidth,
        color: YtColors.surface,
        child: Column(
          children: [
            if (inDrawer)
              SizedBox(
                height: YtSizes.mastheadHeight,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Close menu',
                        icon: const Icon(Icons.menu),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      const SizedBox(width: 16),
                      const Flexible(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: BrandLogo(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 12),
                children: [
                  for (final item in _primary(session))
                    _GuideEntry(
                      item: item,
                      selected: _isSelected(item, uri),
                      onTap: () {
                        if (inDrawer) Navigator.of(context).pop();
                        context.go(item.location);
                      },
                    ),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Divider(),
                  ),
                  if (session is! SessionAuthenticated) ...[
                    const Padding(
                      padding: EdgeInsets.fromLTRB(32, 4, 24, 12),
                      child: Text(
                        'Sign in to upload videos and see your channel.',
                        style: TextStyle(fontSize: 14, height: 1.4),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.only(left: 32, bottom: 16),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: SignInButton(),
                      ),
                    ),
                    const Divider(),
                  ],
                  const Padding(
                    padding: EdgeInsets.fromLTRB(24, 16, 24, 8),
                    child: Text(
                      '© Video Stream',
                      style: TextStyle(
                        fontSize: 12,
                        color: YtColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GuideEntry extends StatelessWidget {
  const _GuideEntry({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final _NavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: true,
    child: Material(
      color: selected ? YtColors.surfaceHigh : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 40,
          child: Row(
            children: [
              const SizedBox(width: 24),
              Icon(selected ? item.selectedIcon : item.icon, size: 24),
              const SizedBox(width: 24),
              Expanded(
                child: Text(
                  item.label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// The collapsed guide: icons with small labels, 72px wide.
class MiniSidebar extends StatelessWidget {
  const MiniSidebar({super.key});

  @override
  Widget build(BuildContext context) {
    final uri = GoRouterState.of(context).uri;
    return BlocBuilder<SessionCubit, SessionState>(
      builder: (context, session) => Container(
        width: YtSizes.miniSidebarWidth,
        color: YtColors.surface,
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          children: [
            for (final item in _primary(session))
              Semantics(
                button: true,
                selected: _isSelected(item, uri),
                child: InkWell(
                  onTap: () => context.go(item.location),
                  child: SizedBox(
                    width: YtSizes.miniSidebarWidth,
                    height: 74,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _isSelected(item, uri)
                              ? item.selectedIcon
                              : item.icon,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          item.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
