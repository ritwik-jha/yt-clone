import 'package:flutter/material.dart';

import '../core/theme.dart';

enum OwnerAction { edit, delete }

/// The ⋮ menu with Edit and Delete, shown only to the video's owner.
class OwnerMenu extends StatelessWidget {
  const OwnerMenu({super.key, required this.onSelected, this.canEdit = true});

  final ValueChanged<OwnerAction> onSelected;

  /// Editing a FAILED video is pointless; Delete is always available.
  final bool canEdit;

  @override
  Widget build(BuildContext context) => PopupMenuButton<OwnerAction>(
    icon: const Icon(Icons.more_vert, color: YtColors.textSecondary),
    tooltip: 'More options',
    onSelected: onSelected,
    itemBuilder: (_) => [
      if (canEdit)
        const PopupMenuItem(
          value: OwnerAction.edit,
          child: ListTile(
            dense: true,
            leading: Icon(Icons.edit_outlined),
            title: Text('Edit'),
          ),
        ),
      const PopupMenuItem(
        value: OwnerAction.delete,
        child: ListTile(
          dense: true,
          leading: Icon(Icons.delete_outline),
          title: Text('Delete'),
        ),
      ),
    ],
  );
}

Future<bool> confirmDelete(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this video?'),
        content: const Text("Delete this video? This can't be undone."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
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
    ) ??
    false;
