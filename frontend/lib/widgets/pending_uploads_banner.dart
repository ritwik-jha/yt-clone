import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../core/theme.dart';
import '../cubits/pending_uploads/pending_uploads_cubit.dart';
import '../models/upload_job.dart';
import '../pages/resume_upload_page.dart';

/// "Unfinished upload" banner with Resume and Discard (PLAN §7.5).
class PendingUploadsBanner extends StatelessWidget {
  const PendingUploadsBanner({super.key});

  @override
  Widget build(BuildContext context) =>
      BlocBuilder<PendingUploadsCubit, List<UploadJob>>(
        builder: (context, jobs) {
          if (jobs.isEmpty) return const SizedBox.shrink();
          final job = jobs.first;
          return Container(
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
            decoration: BoxDecoration(
              color: YtColors.surfaceHigh,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.cloud_upload_outlined,
                  color: YtColors.warning,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Unfinished upload',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        jobs.length > 1
                            ? '${job.title} and ${jobs.length - 1} more'
                            : job.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: YtColors.textSecondary,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    final cubit = context.read<PendingUploadsCubit>();
                    final done = await Navigator.of(context)
                        .push(ResumeUploadPage.route(job));
                    if (done == true) {
                      cubit.completed(job);
                    }
                    await cubit.load();
                  },
                  child: const Text('Resume'),
                ),
                TextButton(
                  onPressed: () =>
                      context.read<PendingUploadsCubit>().discard(job),
                  child: const Text(
                    'Discard',
                    style: TextStyle(color: YtColors.textSecondary),
                  ),
                ),
              ],
            ),
          );
        },
      );
}
