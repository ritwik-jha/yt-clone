import 'package:flutter_test/flutter_test.dart';
import 'package:ytp_app/models/watch_progress.dart';

WatchProgress progress(int pos, {int? dur = 600, bool completed = false}) =>
    WatchProgress(
      videoId: 'v',
      positionSeconds: pos,
      durationSeconds: dur,
      completed: completed,
      lastWatchedAt: DateTime.utc(2026, 10, 3),
    );

void main() {
  test('parses the API shape, in UTC', () {
    final p = WatchProgress.fromJson({
      'video_id': '8f1c',
      'position_seconds': 254,
      'duration_seconds': 612,
      'completed': false,
      'last_watched_at': '2026-10-03T10:15:04.512Z',
    });
    expect(p.videoId, '8f1c');
    expect(p.positionSeconds, 254);
    expect(p.durationSeconds, 612);
    expect(p.lastWatchedAt, DateTime.utc(2026, 10, 3, 10, 15, 4, 512));
    expect(p.lastWatchedAt.isUtc, isTrue);
    final noDuration = WatchProgress.fromJson({
      'video_id': 'x',
      'position_seconds': 1,
      'duration_seconds': null,
      'completed': false,
      'last_watched_at': '2026-10-03T15:45:04+05:30',
    });
    expect(noDuration.durationSeconds, isNull);
    expect(noDuration.lastWatchedAt, DateTime.utc(2026, 10, 3, 10, 15, 4));
  });

  test('fraction: completed is full, unknown duration is empty', () {
    expect(progress(150).fraction, 0.25);
    expect(progress(10, completed: true).fraction, 1);
    expect(progress(10, dur: null).fraction, 0);
    expect(progress(10, dur: 0).fraction, 0);
    expect(progress(900).fraction, 1);
  });

  test('resumeAt: 2 s back, nothing when finished or barely started', () {
    expect(progress(254).resumeAt, const Duration(seconds: 252));
    expect(progress(5).resumeAt, const Duration(seconds: 3));
    expect(progress(4).resumeAt, isNull);
    expect(progress(300, completed: true).resumeAt, isNull);
  });

  test('a report becomes progress with the server completion rule', () {
    WatchProgress of(int pos, int? dur) => WatchProgress.fromReport(
      ProgressReport(
        videoId: 'v',
        positionSeconds: pos,
        durationSeconds: dur,
        watchedAt: DateTime.utc(2026),
      ),
    );
    expect(of(569, 600).completed, isFalse);
    expect(of(570, 600).completed, isTrue); // 95 %
    expect(of(35, 45).completed, isTrue); // 10 s left
    expect(of(34, 45).completed, isFalse);
    expect(of(5000, null).completed, isFalse);
    expect(of(900, 600).positionSeconds, 600); // clamped
  });

  test('isNewerThan', () {
    final a = progress(1);
    final b = WatchProgress(
      videoId: 'v',
      positionSeconds: 2,
      completed: false,
      lastWatchedAt: DateTime.utc(2026, 10, 4),
    );
    expect(b.isNewerThan(a), isTrue);
    expect(a.isNewerThan(b), isFalse);
    expect(a.isNewerThan(a), isFalse);
    expect(a.isNewerThan(null), isTrue);
  });

  test('a report round-trips through storage and sends UTC with Z', () {
    final r = ProgressReport(
      videoId: 'v',
      positionSeconds: 12,
      durationSeconds: 60,
      watchedAt: DateTime.utc(2026, 10, 3, 10, 15, 4, 512),
    );
    final json = r.toJson();
    expect(json['watched_at'], '2026-10-03T10:15:04.512Z');
    expect(ProgressReport.fromJson(json), r);
    final noDuration = ProgressReport(
      videoId: 'v',
      positionSeconds: 1,
      watchedAt: DateTime.utc(2026),
    ).toJson();
    expect(noDuration.containsKey('duration_seconds'), isFalse);
  });

  test('results: the four outcomes, progress only with saved and stale', () {
    final r = ProgressResult.fromJson({
      'video_id': 'v',
      'result': 'stale',
      'progress': {
        'video_id': 'v',
        'position_seconds': 200,
        'duration_seconds': 600,
        'completed': false,
        'last_watched_at': '2026-10-03T10:00:00Z',
      },
    });
    expect(r.outcome, ProgressOutcome.stale);
    expect(r.progress!.positionSeconds, 200);
    for (final (wire, outcome) in [
      ('saved', ProgressOutcome.saved),
      ('not_found', ProgressOutcome.notFound),
      ('expired', ProgressOutcome.expired),
    ]) {
      final parsed = ProgressResult.fromJson({
        'video_id': 'v',
        'result': wire,
        'progress': null,
      });
      expect(parsed.outcome, outcome);
      expect(parsed.progress, isNull);
    }
    expect(() => ProgressOutcome.parse('nope'), throwsFormatException);
  });
}
