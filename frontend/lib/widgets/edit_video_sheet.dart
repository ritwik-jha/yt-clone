import 'package:flutter/material.dart';

import '../core/api_exception.dart';
import '../core/validators.dart';
import '../models/video.dart';

/// Bottom sheet for editing title, description, and visibility. Save stays
/// disabled until something changes, and only changed fields are sent.
Future<bool> showEditVideoSheet(
  BuildContext context, {
  required Video video,
  required Future<void> Function(VideoUpdate changes) onSave,
}) async =>
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => EditVideoSheet(video: video, onSave: onSave),
    ) ??
    false;

class EditVideoSheet extends StatefulWidget {
  const EditVideoSheet({super.key, required this.video, required this.onSave});

  final Video video;
  final Future<void> Function(VideoUpdate changes) onSave;

  @override
  State<EditVideoSheet> createState() => _EditVideoSheetState();
}

class _EditVideoSheetState extends State<EditVideoSheet> {
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
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Edit video',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _title,
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
                  errorText: _fieldErrors['description'],
                ),
                validator: Validators.description,
                maxLines: 4,
                minLines: 2,
                maxLength: Validators.descriptionMax,
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<VideoVisibility>(
                initialValue: _visibility,
                decoration: InputDecoration(
                  labelText: 'Visibility',
                  errorText: _fieldErrors['visibility'],
                ),
                items:
                    const [
                          VideoVisibility.public,
                          VideoVisibility.private,
                          VideoVisibility.unlisted,
                        ]
                        .map(
                          (v) =>
                              DropdownMenuItem(value: v, child: Text(v.label)),
                        )
                        .toList(),
                onChanged: (v) =>
                    setState(() => _visibility = v ?? _visibility),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: changed && !_saving ? _save : null,
                child: _saving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
