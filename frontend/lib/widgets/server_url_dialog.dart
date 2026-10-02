import 'package:flutter/material.dart';

import '../core/config.dart';
import '../core/server_settings.dart';
import '../core/theme.dart';

/// Dev-only control for the backend URL. Renders nothing in builds where
/// [ServerSettings.canChange] is false.
class ServerUrlButton extends StatelessWidget {
  const ServerUrlButton({super.key, required this.settings});
  final ServerSettings settings;

  @override
  Widget build(BuildContext context) {
    if (!settings.canChange) return const SizedBox.shrink();
    return IconButton(
      tooltip: 'Backend server',
      icon: const Icon(Icons.dns_outlined),
      onPressed: () => showServerUrlDialog(context, settings),
    );
  }
}

Future<void> showServerUrlDialog(
  BuildContext context,
  ServerSettings settings,
) => showDialog<void>(
  context: context,
  builder: (_) => _ServerUrlDialog(settings: settings),
);

class _ServerUrlDialog extends StatefulWidget {
  const _ServerUrlDialog({required this.settings});
  final ServerSettings settings;

  @override
  State<_ServerUrlDialog> createState() => _ServerUrlDialogState();
}

class _ServerUrlDialogState extends State<_ServerUrlDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _controller = TextEditingController(
    text: widget.settings.url ?? '',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final navigator = Navigator.of(context);
    final changed =
        ServerSettings.normalize(_controller.text) != widget.settings.url;
    await widget.settings.update(_controller.text);
    if (!mounted) return;
    navigator.pop();
    if (changed) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Server changed. Please sign in again.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final fallback = widget.settings.compileTimeUrl;
    return AlertDialog(
      title: const Text('Backend server'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextFormField(
              controller: _controller,
              autofocus: true,
              keyboardType: TextInputType.url,
              autocorrect: false,
              validator: ServerSettings.validate,
              onFieldSubmitted: (_) => _save(),
              decoration: const InputDecoration(
                labelText: 'API base URL',
                hintText: 'http://10.0.2.2:8000',
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Android emulator: http://10.0.2.2:8000\n'
              'iOS simulator: http://127.0.0.1:8000\n'
              'Physical device: http://<your LAN IP>:8000',
              style: TextStyle(color: YtColors.textSecondary, fontSize: 12.5),
            ),
            if (AppConfig.apiBaseUrl.isNotEmpty && fallback != null) ...[
              const SizedBox(height: 8),
              Text(
                'Build default: $fallback',
                style: const TextStyle(
                  color: YtColors.textSecondary,
                  fontSize: 12.5,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (AppConfig.apiBaseUrl.isNotEmpty)
          TextButton(
            onPressed: () async {
              final nav = Navigator.of(context);
              await widget.settings.reset();
              nav.pop();
            },
            child: const Text('Use build default'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
