import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/format.dart';
import '../core/theme.dart';
import '../cubits/upload_video/upload_video_cubit.dart';
import '../cubits/upload_video/upload_video_state.dart';
import '../models/upload_job.dart';
import '../services/upload_job_store.dart';
import '../services/upload_video_service.dart';

/// Finishes an upload that was interrupted (e.g. the app was killed).
/// Pops with `true` when the job completed.
class ResumeUploadPage extends StatelessWidget {
  const ResumeUploadPage({super.key, required this.job});
  final UploadJob job;

  static Route<bool> route(UploadJob job) => MaterialPageRoute(
    builder: (ctx) => BlocProvider(
      create: (_) => UploadVideoCubit(
        ctx.read<UploadVideoService>(),
        store: ctx.read<UploadJobStore>(),
      )..resume(job),
      child: ResumeUploadPage(job: job),
    ),
  );

  @override
  Widget build(BuildContext context) =>
      BlocConsumer<UploadVideoCubit, UploadVideoState>(
        listener: (context, state) {
          if (state is UploadVideoInProgress) {
            WakelockPlus.enable();
          } else {
            WakelockPlus.disable();
          }
          if (state is UploadVideoSuccess) {
            Navigator.of(context).pop(true);
          }
        },
        builder: (context, state) {
          final cubit = context.read<UploadVideoCubit>();
          return PopScope(
            canPop: state is! UploadVideoInProgress,
            child: Scaffold(
              appBar: AppBar(title: const Text('Resume upload')),
              body: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      job.title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 20),
                    switch (state) {
                      UploadVideoInProgress() => Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            state.stage.label,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 8),
                          LinearProgressIndicator(
                            value: state.fraction,
                            minHeight: 6,
                          ),
                          if (state.totalBytes > 0 &&
                              state.stage == UploadStage.video)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                '${formatBytes(state.sentBytes)} of '
                                '${formatBytes(state.totalBytes)}',
                                style: const TextStyle(
                                  color: YtColors.textSecondary,
                                  fontSize: 12.5,
                                ),
                              ),
                            ),
                          const SizedBox(height: 16),
                          OutlinedButton(
                            onPressed: cubit.cancel,
                            child: const Text('Cancel and discard'),
                          ),
                        ],
                      ),
                      UploadVideoError() => Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            state.message,
                            style: const TextStyle(color: Color(0xFFFF6E6E)),
                          ),
                          const SizedBox(height: 16),
                          if (state.retryable)
                            FilledButton(
                              onPressed: cubit.retry,
                              child: const Text('Retry'),
                            ),
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(false),
                            child: const Text('Close'),
                          ),
                        ],
                      ),
                      UploadVideoInitial() => Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text('Upload cancelled.'),
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(true),
                            child: const Text('Close'),
                          ),
                        ],
                      ),
                      UploadVideoSuccess() => const Center(
                        child: CircularProgressIndicator(),
                      ),
                    },
                  ],
                ),
              ),
            ),
          );
        },
      );
}
