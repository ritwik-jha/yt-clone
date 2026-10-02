import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/api_exception.dart';
import '../../models/upload_job.dart';
import '../../services/upload_job_store.dart';
import '../../services/upload_video_service.dart';

/// Unfinished uploads found on launch (PLAN §7.5). Shown as a banner on Home.
class PendingUploadsCubit extends Cubit<List<UploadJob>> {
  PendingUploadsCubit(this._store, this._service) : super(const []);

  final UploadJobStore _store;
  final UploadVideoService _service;

  /// On each authenticated launch:
  ///  1. a job whose video is in S3 but never saved is saved at once, because
  ///     the backend only keeps a parked transcode result for 7 days;
  ///  2. any other unfinished job becomes a Resume/Discard banner.
  Future<void> load() async {
    final remaining = <UploadJob>[];
    for (final job in await _store.list()) {
      if (job.savedVideoId != null) {
        await _store.delete(job);
        continue;
      }
      if (job.needsSave) {
        try {
          await _service.save(
            title: job.title,
            description: job.description,
            visibility: job.visibility,
            videoKey: job.videoKey!,
            thumbnailKey: job.thumbnailKey!,
          );
          await _store.delete(job);
          continue;
        } on ApiException catch (e) {
          if (e.code == 'already_saved') {
            await _store.delete(job);
            continue;
          }
          // Couldn't save right now: leave it for Resume.
        }
      }
      remaining.add(job);
    }
    if (!isClosed) emit(remaining);
  }

  Future<void> discard(UploadJob job) async {
    await _store.delete(job);
    emit(state.where((j) => j.localId != job.localId).toList());
  }

  /// Called after a resumed job completes.
  void completed(UploadJob job) =>
      emit(state.where((j) => j.localId != job.localId).toList());
}
