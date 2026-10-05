import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/upload_job.dart';
import '../models/video.dart';

/// Persists [UploadJob]s under `<app support>/uploads/<localId>/`.
///
/// Files are copied into application support, not Documents: on iOS the
/// Documents folder can show up in the Files app, and these are temporary.
class UploadJobStore {
  UploadJobStore({Future<Directory> Function()? rootProvider})
    : _rootProvider = rootProvider ?? _defaultRoot;

  final Future<Directory> Function() _rootProvider;

  static Future<Directory> _defaultRoot() async {
    final base = await getApplicationSupportDirectory();
    return Directory(p.join(base.path, 'uploads'));
  }

  Future<Directory> _dir(String localId) async {
    final root = await _rootProvider();
    return Directory(p.join(root.path, localId));
  }

  /// Copies both files into the job's directory and writes `job.json`.
  Future<UploadJob> create({
    required String title,
    required String description,
    required VideoVisibility visibility,
    required File video,
    required File thumbnail,
  }) async {
    final localId = DateTime.now().microsecondsSinceEpoch.toString();
    final dir = await _dir(localId);
    await dir.create(recursive: true);
    final videoCopy = await video.copy(
      p.join(dir.path, 'video${p.extension(video.path)}'),
    );
    final thumbCopy = await thumbnail.copy(p.join(dir.path, 'thumbnail.jpg'));
    final job = UploadJob(
      localId: localId,
      title: title,
      description: description,
      visibility: visibility,
      videoPath: videoCopy.path,
      thumbnailPath: thumbCopy.path,
    );
    await save(job);
    return job;
  }

  /// Atomic write: a kill between write and rename leaves the old file.
  Future<void> save(UploadJob job) async {
    final dir = await _dir(job.localId);
    await dir.create(recursive: true);
    final tmp = File(p.join(dir.path, 'job.json.tmp'));
    await tmp.writeAsString(jsonEncode(job.toJson()), flush: true);
    await tmp.rename(p.join(dir.path, 'job.json'));
  }

  Future<List<UploadJob>> list() async {
    // The web build has no file system (path_provider throws there), so it
    // never has a job to resume.
    if (kIsWeb) return const [];
    final root = await _rootProvider();
    if (!await root.exists()) return [];
    final jobs = <UploadJob>[];
    await for (final entity in root.list()) {
      if (entity is! Directory) continue;
      final file = File(p.join(entity.path, 'job.json'));
      if (!await file.exists()) continue;
      try {
        jobs.add(
          UploadJob.fromJson(
            jsonDecode(await file.readAsString()) as Map<String, dynamic>,
          ),
        );
      } catch (_) {
        // A corrupt job can't be resumed; drop it rather than loop on it.
        await entity.delete(recursive: true);
      }
    }
    jobs.sort((a, b) => a.localId.compareTo(b.localId));
    return jobs;
  }

  Future<void> delete(UploadJob job) async {
    final dir = await _dir(job.localId);
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
