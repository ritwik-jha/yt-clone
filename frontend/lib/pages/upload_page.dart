import 'dart:io';

import 'package:dotted_border/dotted_border.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/config.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../core/validators.dart';
import '../cubits/upload_video/upload_video_cubit.dart';
import '../cubits/upload_video/upload_video_state.dart';
import '../models/video.dart';
import '../services/upload_job_store.dart';
import '../services/upload_video_service.dart';
import 'my_videos_page.dart';

class UploadPage extends StatelessWidget {
  const UploadPage({super.key});

  static Route<void> route() => MaterialPageRoute(
    builder: (ctx) => BlocProvider(
      create: (_) => UploadVideoCubit(
        ctx.read<UploadVideoService>(),
        store: ctx.read<UploadJobStore>(),
      ),
      child: const UploadPage(),
    ),
  );

  @override
  Widget build(BuildContext context) => const _UploadView();
}

class _UploadView extends StatefulWidget {
  const _UploadView();

  @override
  State<_UploadView> createState() => _UploadViewState();
}

class _UploadViewState extends State<_UploadView> {
  static const _videoExtensions = {'.mp4', '.mov', '.m4v'};

  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _picker = ImagePicker();

  File? _thumbnail;
  File? _video;
  int _videoBytes = 0;
  VideoVisibility _visibility = VideoVisibility.private;
  String? _thumbnailError;
  String? _videoError;
  bool _preparing = false;

  @override
  void initState() {
    super.initState();
    for (final c in [_title, _description]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  bool get _valid =>
      _thumbnail != null &&
      _video != null &&
      Validators.videoTitle(_title.text) == null &&
      Validators.description(_description.text) == null;

  Future<void> _pickThumbnail() async {
    final picked = await _picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    setState(() {
      _preparing = true;
      _thumbnailError = null;
    });
    try {
      // The presigned URL is signed for image/jpeg: re-encode whatever was picked.
      final dir = await getTemporaryDirectory();
      final target = p.join(
        dir.path,
        'thumb_${DateTime.now().microsecondsSinceEpoch}.jpg',
      );
      final out = await FlutterImageCompress.compressAndGetFile(
        picked.path,
        target,
        format: CompressFormat.jpeg,
        quality: 85,
        minWidth: 1280,
        minHeight: 720,
      );
      if (out == null) throw StateError('re-encode failed');
      if (mounted) setState(() => _thumbnail = File(out.path));
    } catch (_) {
      if (mounted) setState(() => _thumbnailError = "Couldn't read that image");
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  Future<void> _pickVideo() async {
    final picked = await _picker.pickVideo(source: ImageSource.gallery);
    if (picked == null) return;
    final file = File(picked.path);
    final size = await file.length();
    final ext = p.extension(picked.path).toLowerCase();
    String? error;
    if (!_videoExtensions.contains(ext)) {
      error = 'Choose an .mp4, .mov, or .m4v file';
    } else if (size == 0) {
      error = 'That file is empty';
    } else if (size > AppConfig.maxUploadBytes) {
      error = 'Videos can be at most ${formatBytes(AppConfig.maxUploadBytes)}';
    }
    if (!mounted) return;
    setState(() {
      _videoError = error;
      _video = error == null ? file : null;
      _videoBytes = error == null ? size : 0;
    });
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _thumbnailError = _thumbnail == null ? 'Select a thumbnail' : null;
      _videoError = _video == null ? 'Select a video file' : null;
    });
    if (_thumbnail == null || _video == null) return;
    await WakelockPlus.enable();
    if (!mounted) return;
    await context.read<UploadVideoCubit>().uploadVideo(
      title: _title.text,
      description: _description.text,
      visibility: _visibility,
      video: _video!,
      thumbnail: _thumbnail!,
    );
  }

  Future<bool> _confirmLeave() async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Cancel upload?'),
          content: const Text(
            'The upload will stop and nothing will be saved.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep uploading'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text(
                'Cancel upload',
                style: TextStyle(color: Color(0xFFFF6E6E)),
              ),
            ),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(
    BuildContext context,
  ) => BlocConsumer<UploadVideoCubit, UploadVideoState>(
    listener: (context, state) {
      switch (state) {
        case UploadVideoSuccess():
          WakelockPlus.disable();
          final messenger = ScaffoldMessenger.of(context);
          final navigator = Navigator.of(context);
          messenger.showSnackBar(
            SnackBar(
              content: const Text('Video uploaded. Processing has started.'),
              action: SnackBarAction(
                label: 'My videos',
                onPressed: () => navigator.push(MyVideosPage.route()),
              ),
            ),
          );
          navigator.pop();
        case UploadVideoError(:final message):
          WakelockPlus.disable();
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(message)));
        default:
      }
    },
    builder: (context, state) {
      final uploading = state is UploadVideoInProgress;
      return PopScope(
        canPop: !uploading,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          final cubit = context.read<UploadVideoCubit>();
          final navigator = Navigator.of(context);
          if (await _confirmLeave()) {
            cubit.cancel();
            navigator.pop();
          }
        },
        child: Scaffold(
          appBar: AppBar(title: const Text('Upload video')),
          body: SafeArea(
            child: AbsorbPointer(
              absorbing: uploading,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _PickerBox(
                    height: 170,
                    icon: Icons.image_outlined,
                    label: 'Select the thumbnail for your video',
                    error: _thumbnailError,
                    busy: _preparing,
                    onTap: _pickThumbnail,
                    child: _thumbnail == null
                        ? null
                        : ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Image.file(
                              _thumbnail!,
                              fit: BoxFit.cover,
                              width: double.infinity,
                            ),
                          ),
                  ),
                  const SizedBox(height: 14),
                  _PickerBox(
                    height: 96,
                    icon: Icons.video_file_outlined,
                    label: 'Select your video file',
                    error: _videoError,
                    onTap: _pickVideo,
                    child: _video == null
                        ? null
                        : Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.movie_outlined,
                                  color: YtColors.textSecondary,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        p.basename(_video!.path),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      Text(
                                        formatBytes(_videoBytes),
                                        style: const TextStyle(
                                          color: YtColors.textSecondary,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                  ),
                  const SizedBox(height: 20),
                  Form(
                    key: _formKey,
                    child: Column(
                      children: [
                        TextFormField(
                          controller: _title,
                          maxLength: 100,
                          textInputAction: TextInputAction.next,
                          decoration: const InputDecoration(labelText: 'Title'),
                          validator: Validators.videoTitle,
                        ),
                        const SizedBox(height: 8),
                        TextFormField(
                          controller: _description,
                          maxLines: null,
                          minLines: 3,
                          maxLength: Validators.descriptionMax,
                          decoration: const InputDecoration(
                            labelText: 'Description',
                          ),
                          validator: Validators.description,
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<VideoVisibility>(
                          initialValue: _visibility,
                          decoration: const InputDecoration(
                            labelText: 'Visibility',
                          ),
                          items:
                              const [
                                    VideoVisibility.public,
                                    VideoVisibility.private,
                                    VideoVisibility.unlisted,
                                  ]
                                  .map(
                                    (v) => DropdownMenuItem(
                                      value: v,
                                      child: Text(v.label),
                                    ),
                                  )
                                  .toList(),
                          onChanged: (v) =>
                              setState(() => _visibility = v ?? _visibility),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (uploading)
                    _Progress(state: state)
                  else ...[
                    FilledButton.icon(
                      onPressed: _valid && !_preparing ? _submit : null,
                      icon: const Icon(Icons.upload_rounded),
                      label: Text(
                        state is UploadVideoError ? 'Retry upload' : 'Upload',
                      ),
                    ),
                    if (state is UploadVideoError && !state.retryable)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          'This error can’t be fixed by retrying.',
                          style: TextStyle(color: YtColors.textSecondary),
                        ),
                      ),
                  ],
                  const SizedBox(height: 12),
                  const Text(
                    'Keep the app open until the upload finishes.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: YtColors.textSecondary,
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _Progress extends StatelessWidget {
  const _Progress({required this.state});
  final UploadVideoInProgress state;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        state.stage.label,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      LinearProgressIndicator(value: state.fraction, minHeight: 6),
      if (state.stage == UploadStage.video && state.totalBytes > 0)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            '${formatBytes(state.sentBytes)} of ${formatBytes(state.totalBytes)}',
            style: const TextStyle(
              color: YtColors.textSecondary,
              fontSize: 12.5,
            ),
          ),
        ),
      const SizedBox(height: 12),
      // AbsorbPointer above stops taps on the form, not on this button.
      OutlinedButton(
        onPressed: () => context.read<UploadVideoCubit>().cancel(),
        child: const Text('Cancel'),
      ),
    ],
  );
}

class _PickerBox extends StatelessWidget {
  const _PickerBox({
    required this.height,
    required this.icon,
    required this.label,
    required this.onTap,
    this.child,
    this.error,
    this.busy = false,
  });

  final double height;
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Widget? child;
  final String? error;
  final bool busy;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      InkWell(
        onTap: busy ? null : onTap,
        borderRadius: BorderRadius.circular(10),
        child: DottedBorder(
          options: RoundedRectDottedBorderOptions(
            radius: const Radius.circular(10),
            dashPattern: const [10, 4],
            color: error == null
                ? YtColors.textSecondary
                : const Color(0xFFFF6E6E),
            strokeWidth: 1.2,
          ),
          child: SizedBox(
            height: height,
            width: double.infinity,
            child: busy
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : child ??
                      Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(icon, size: 32, color: YtColors.textSecondary),
                          const SizedBox(height: 8),
                          Text(
                            label,
                            style: const TextStyle(
                              color: YtColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
          ),
        ),
      ),
      if (error != null)
        Padding(
          padding: const EdgeInsets.only(top: 6, left: 4),
          child: Text(
            error!,
            style: const TextStyle(color: Color(0xFFFF6E6E), fontSize: 12.5),
          ),
        ),
    ],
  );
}
