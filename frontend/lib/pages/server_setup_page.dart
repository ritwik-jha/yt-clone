import 'package:flutter/material.dart';

import '../core/server_settings.dart';
import '../core/theme.dart';
import '../widgets/auth_scaffold.dart';

/// Shown in dev builds when no backend URL has been provided yet.
class ServerSetupPage extends StatefulWidget {
  const ServerSetupPage({super.key, required this.settings});
  final ServerSettings settings;

  @override
  State<ServerSetupPage> createState() => _ServerSetupPageState();
}

class _ServerSetupPageState extends State<ServerSetupPage> {
  final _formKey = GlobalKey<FormState>();
  final _controller = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    await widget.settings.update(_controller.text);
  }

  @override
  Widget build(BuildContext context) => AuthScaffold(
    title: 'Connect to a server',
    subtitle: 'Enter the backend API URL. You can change it later.',
    children: [
      Form(
        key: _formKey,
        child: TextFormField(
          controller: _controller,
          keyboardType: TextInputType.url,
          autocorrect: false,
          validator: ServerSettings.validate,
          onFieldSubmitted: (_) => _save(),
          decoration: const InputDecoration(
            labelText: 'API base URL',
            hintText: 'http://10.0.2.2:8000',
          ),
        ),
      ),
      const SizedBox(height: 10),
      const Text(
        'Android emulator: http://10.0.2.2:8000\n'
        'iOS simulator: http://127.0.0.1:8000\n'
        'Physical device: http://<your LAN IP>:8000\n'
        'Deployed: terraform -chdir=backend/terraform output -raw api_url',
        style: TextStyle(color: YtColors.textSecondary, fontSize: 12.5),
      ),
      const SizedBox(height: 20),
      FilledButton(
        onPressed: _saving ? null : _save,
        child: LoadingLabel(loading: _saving, label: 'Connect'),
      ),
    ],
  );
}
