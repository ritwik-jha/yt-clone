import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../app/routes.dart';
import '../core/config.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../core/validators.dart';
import '../cubits/session/session_cubit.dart';
import '../cubits/session/session_state.dart';
import '../cubits/upload_video/upload_video_cubit.dart';
import '../cubits/upload_video/upload_video_state.dart';
import '../models/video.dart';
import '../platform/browser.dart';

/// `/upload`: pick or drop an MP4, fill in the details, upload.
///
/// The upload itself belongs to the app-wide [UploadVideoCubit], so it keeps
/// going while the user browses; this page shows its progress whenever one
/// is running or just ended.
class UploadPage extends StatelessWidget {
  const UploadPage({super.key});

  @override
  Widget build(BuildContext context) => BlocBuilder<SessionCubit, SessionState>(
    buildWhen: (a, b) => a.runtimeType != b.runtimeType,
    builder: (context, session) => session is! SessionAuthenticated
        ? const Center(child: CircularProgressIndicator())
        : BlocBuilder<UploadVideoCubit, UploadVideoState>(
            buildWhen: (a, b) =>
                (a is UploadVideoInitial) != (b is UploadVideoInitial),
            builder: (context, state) => SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 960),
                  child: Material(
                    color: YtColors.surface,
                    child: state is UploadVideoInitial
                        ? const _UploadForm()
                        : const _UploadProgress(),
                  ),
                ),
              ),
            ),
          ),
  );
}

class _Header extends StatelessWidget {
  const _Header(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(24, 16, 16, 16),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: YtColors.divider)),
    ),
    child: Text(title, style: const TextStyle(fontSize: 20)),
  );
}

class _UploadForm extends StatefulWidget {
  const _UploadForm();

  @override
  State<_UploadForm> createState() => _UploadFormState();
}

class _UploadFormState extends State<_UploadForm> {
  late final Browser _browser = context.read<Browser>();
  late final void Function() _stopDrops;
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _description = TextEditingController();
  VideoVisibility _visibility = VideoVisibility.public;

  PickedFile? _video;
  PickedFile? _thumbnail;
  String? _thumbnailUrl;
  bool _capturing = false;
  String? _fileError;
  String? _thumbnailError;

  @override
  void initState() {
    super.initState();
    _stopDrops = _browser.listenForDrops(_takeVideo);
  }

  @override
  void dispose() {
    _stopDrops();
    if (_thumbnailUrl != null) _browser.revokeUrl(_thumbnailUrl!);
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  static bool _isMp4(PickedFile f) =>
      f.type == 'video/mp4' || f.name.toLowerCase().endsWith('.mp4');

  Future<void> _pickVideo() async {
    final file = await _browser.pickFile(accept: 'video/mp4,.mp4');
    if (file != null) await _takeVideo(file);
  }

  Future<void> _takeVideo(PickedFile file) async {
    if (!mounted) return;
    if (!_isMp4(file)) {
      setState(() => _fileError = 'Choose an MP4 video file.');
      return;
    }
    if (file.size > AppConfig.maxUploadBytes) {
      setState(
        () => _fileError =
            'That file is ${formatBytes(file.size)}. The limit is '
            '${formatBytes(AppConfig.maxUploadBytes)}.',
      );
      return;
    }
    setState(() {
      _video = file;
      _fileError = null;
      _thumbnailError = null;
      _capturing = true;
      if (_title.text.trim().isEmpty) {
        final dot = file.name.lastIndexOf('.');
        final stem = dot > 0 ? file.name.substring(0, dot) : file.name;
        _title.text = stem.length > 100 ? stem.substring(0, 100) : stem;
      }
    });
    final frame = await _browser.captureFrame(file);
    if (!mounted) return;
    setState(() {
      _capturing = false;
      if (frame == null) {
        _thumbnailError =
            "Couldn't take a thumbnail from this video. Choose an image.";
      }
    });
    if (frame != null) _setThumbnail(frame);
  }

  Future<void> _pickThumbnail() async {
    final image = await _browser.pickFile(accept: 'image/*');
    if (image == null || !mounted) return;
    final jpeg = await _browser.toJpeg(image);
    if (!mounted) return;
    if (jpeg == null) {
      setState(() => _thumbnailError = "That image couldn't be read.");
      return;
    }
    _setThumbnail(jpeg);
  }

  void _setThumbnail(PickedFile jpeg) {
    if (_thumbnailUrl != null) _browser.revokeUrl(_thumbnailUrl!);
    setState(() {
      _thumbnail = jpeg;
      _thumbnailUrl = _browser.objectUrl(jpeg);
      _thumbnailError = null;
    });
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    if (_thumbnail == null) {
      setState(() => _thumbnailError = 'Add a thumbnail.');
      return;
    }
    context.read<UploadVideoCubit>().upload(
      UploadDraft(
        title: _title.text.trim(),
        description: _description.text.trim(),
        visibility: _visibility,
        video: _video!,
        thumbnail: _thumbnail!,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_video == null) return _dropZone();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Header('Details'),
        Padding(
          padding: const EdgeInsets.all(24),
          child: LayoutBuilder(
            builder: (context, c) {
              final form = _details();
              final side = _preview();
              return c.maxWidth >= 720
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: form),
                        const SizedBox(width: 24),
                        SizedBox(width: 300, child: side),
                      ],
                    )
                  : Column(children: [side, const SizedBox(height: 24), form]);
            },
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: YtColors.divider)),
          ),
          child: Row(
            children: [
              TextButton(
                onPressed: () => setState(() {
                  _video = null;
                  _thumbnail = null;
                }),
                child: const Text('CHOOSE ANOTHER FILE'),
              ),
              const Spacer(),
              FilledButton(
                onPressed: _capturing ? null : _submit,
                child: const Text('UPLOAD'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _dropZone() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const _Header('Upload video'),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 72, horizontal: 24),
        child: Column(
          children: [
            Semantics(
              button: true,
              label: 'Select a video file',
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _pickVideo,
                child: Container(
                  width: 136,
                  height: 136,
                  decoration: const BoxDecoration(
                    color: YtColors.field,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.file_upload_outlined,
                    size: 64,
                    color: YtColors.textSecondary,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Drag and drop a video file to upload',
              style: TextStyle(fontSize: 15),
            ),
            const SizedBox(height: 4),
            Text(
              'MP4, up to ${formatBytes(AppConfig.maxUploadBytes)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_fileError != null) ...[
              const SizedBox(height: 12),
              Text(_fileError!, style: const TextStyle(color: YtColors.error)),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _pickVideo,
              child: const Text('SELECT FILE'),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _details() => Form(
    key: _formKey,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          controller: _title,
          decoration: const InputDecoration(
            labelText: 'Title (required)',
            hintText: 'Add a title that describes your video',
          ),
          validator: Validators.videoTitle,
          maxLength: 100,
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _description,
          decoration: const InputDecoration(
            labelText: 'Description',
            hintText: 'Tell viewers about your video',
            alignLabelWithHint: true,
          ),
          validator: Validators.description,
          minLines: 5,
          maxLines: 10,
          maxLength: Validators.descriptionMax,
        ),
        const SizedBox(height: 16),
        const Text('Visibility', style: TextStyle(fontSize: 16)),
        const SizedBox(height: 4),
        RadioGroup<VideoVisibility>(
          groupValue: _visibility,
          onChanged: (v) => setState(() => _visibility = v ?? _visibility),
          child: Column(
            children: [
              for (final v in VideoVisibility.choices)
                RadioListTile<VideoVisibility>(
                  value: v,
                  contentPadding: EdgeInsets.zero,
                  title: Text(v.label),
                  subtitle: Text(switch (v) {
                    VideoVisibility.public => 'Everyone can find and watch it',
                    VideoVisibility.unlisted =>
                      'Anyone with the link can watch it',
                    _ => 'Only you can watch it',
                  }),
                ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _preview() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      AspectRatio(
        aspectRatio: 16 / 9,
        child: ColoredBox(
          color: Colors.black,
          child: _capturing
              ? const Center(child: CircularProgressIndicator())
              : _thumbnailUrl == null
              ? const Center(
                  child: Icon(
                    Icons.image_outlined,
                    size: 48,
                    color: YtColors.textSecondary,
                  ),
                )
              : Image.network(
                  _thumbnailUrl!,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const Center(
                    child: Icon(
                      Icons.image_outlined,
                      size: 48,
                      color: YtColors.textSecondary,
                    ),
                  ),
                ),
        ),
      ),
      Container(
        color: YtColors.field,
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Filename', style: Theme.of(context).textTheme.bodySmall),
            Text(_video!.name, maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 4),
            Text(
              formatBytes(_video!.size),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: _capturing ? null : _pickThumbnail,
        icon: const Icon(Icons.add_photo_alternate_outlined),
        label: Text(
          _thumbnail == null ? 'UPLOAD THUMBNAIL' : 'CHANGE THUMBNAIL',
        ),
      ),
      if (_thumbnailError != null) ...[
        const SizedBox(height: 8),
        Text(_thumbnailError!, style: const TextStyle(color: YtColors.error)),
      ],
    ],
  );
}

class _UploadProgress extends StatelessWidget {
  const _UploadProgress();

  @override
  Widget build(BuildContext context) =>
      BlocBuilder<UploadVideoCubit, UploadVideoState>(
        builder: (context, state) {
          final cubit = context.read<UploadVideoCubit>();
          final title = cubit.draft?.title ?? '';
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(title.isEmpty ? 'Upload' : title),
              Padding(
                padding: const EdgeInsets.all(24),
                child: switch (state) {
                  UploadVideoInProgress(
                    :final stage,
                    :final fraction,
                    :final sentBytes,
                    :final totalBytes,
                  ) =>
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${stage.label}…',
                          style: const TextStyle(fontSize: 16),
                        ),
                        const SizedBox(height: 16),
                        LinearProgressIndicator(value: fraction, minHeight: 6),
                        const SizedBox(height: 8),
                        Text(
                          fraction == null
                              ? 'Keep this tab open until the upload finishes.'
                              : '${(fraction * 100).round()}% • '
                                    '${formatBytes(sentBytes)} of '
                                    '${formatBytes(totalBytes)}. Keep this tab '
                                    'open until the upload finishes.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 24),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: cubit.cancel,
                            child: const Text('CANCEL UPLOAD'),
                          ),
                        ),
                      ],
                    ),
                  UploadVideoError(:final message, :final retryable) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.error_outline, color: YtColors.error),
                          SizedBox(width: 12),
                          Text('Upload failed', style: TextStyle(fontSize: 16)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(message),
                      const SizedBox(height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: cubit.reset,
                            child: const Text('DISCARD'),
                          ),
                          if (retryable) ...[
                            const SizedBox(width: 8),
                            FilledButton(
                              onPressed: cubit.retry,
                              child: const Text('RETRY'),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                  UploadVideoSuccess() => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.check_circle, color: YtColors.success),
                          SizedBox(width: 12),
                          Text(
                            'Upload complete',
                            style: TextStyle(fontSize: 16),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        "Your video is processing. It will be ready to watch "
                        "in Your videos in a few minutes.",
                      ),
                      const SizedBox(height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: cubit.reset,
                            child: const Text('UPLOAD ANOTHER'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: () {
                              cubit.reset();
                              context.go(Routes.myVideos);
                            },
                            child: const Text('GO TO YOUR VIDEOS'),
                          ),
                        ],
                      ),
                    ],
                  ),
                  UploadVideoInitial() => const SizedBox.shrink(),
                },
              ),
            ],
          );
        },
      );
}
