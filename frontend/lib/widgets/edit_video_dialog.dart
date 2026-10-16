import 'package:flutter/material.dart';

import '../core/api_exception.dart';
import '../core/theme.dart';
import '../core/validators.dart';
import '../models/video.dart';

/// Dialog for editing title, description, and visibility. Save stays
/// disabled until something changes, and only changed fields are sent.
Future<bool> showEditVideoDialog(
  BuildContext context, {
  required Video video,
  required Future<void> Function(VideoUpdate changes) onSave,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => EditVideoDialog(video: video, onSave: onSave),
    ) ??
    false;

/// Asks before deleting [title]; true to go ahead.
Future<bool> confirmDeleteVideo(BuildContext context, String title) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Permanently delete this video?'),
        content: Text(
          '"$title" will be deleted for everyone. This can\'t be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: YtColors.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('DELETE'),
          ),
        ],
      ),
    ) ??
    false;

class EditVideoDialog extends StatefulWidget {
  const EditVideoDialog({super.key, required this.video, required this.onSave});

  final Video video;
  final Future<void> Function(VideoUpdate changes) onSave;

  @override
  State<EditVideoDialog> createState() => _EditVideoDialogState();
}

class _EditVideoDialogState extends State<EditVideoDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _title = TextEditingController(text: widget.video.title);
  late final _description = TextEditingController(
    text: widget.video.description ?? '',
  );
  late VideoVisibility _visibility = widget.video.effectiveVisibility;
  bool _saving = false;
  Map<String, String> _fieldErrors = {};

  VideoUpdate get _changes {
    final v = widget.video;
    final title = _title.text.trim();
    final description = _description.text.trim();
    return VideoUpdate(
      title: title != v.title ? title : null,
      description: description != (v.description ?? '') ? description : null,
      visibility: _visibility != v.effectiveVisibility ? _visibility : null,
    );
  }

  @override
  void initState() {
    super.initState();
    _title.addListener(_refresh);
    _description.addListener(_refresh);
  }

  void _refresh() => setState(() => _fieldErrors = {});

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await widget.onSave(_changes);
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      if (e.code == 'video_not_found') {
        Navigator.pop(context, false);
      } else if (e.fieldErrors.isNotEmpty) {
        setState(() => _fieldErrors = e.fieldErrors);
      } else {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final changed = !_changes.isEmpty;
    return AlertDialog(
      title: const Text('Video details'),
      content: SizedBox(
        width: 560,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 8),
                TextFormField(
                  controller: _title,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: 'Title',
                    errorText: _fieldErrors['title'],
                  ),
                  validator: Validators.videoTitle,
                  maxLength: 100,
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _description,
                  decoration: InputDecoration(
                    labelText: 'Description',
                    alignLabelWithHint: true,
                    errorText: _fieldErrors['description'],
                  ),
                  validator: Validators.description,
                  maxLines: 6,
                  minLines: 3,
                  maxLength: Validators.descriptionMax,
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<VideoVisibility>(
                  initialValue: _visibility,
                  decoration: InputDecoration(
                    labelText: 'Visibility',
                    errorText: _fieldErrors['visibility'],
                  ),
                  items: [
                    for (final v in VideoVisibility.choices)
                      DropdownMenuItem(value: v, child: Text(v.label)),
                  ],
                  onChanged: (v) =>
                      setState(() => _visibility = v ?? _visibility),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('CANCEL'),
        ),
        FilledButton(
          onPressed: changed && !_saving ? _save : null,
          child: _saving
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('SAVE'),
        ),
      ],
    );
  }
}
