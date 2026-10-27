import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ytp_app/models/watch_progress.dart';
import 'package:ytp_app/platform/video_player.dart';
import 'package:ytp_app/platform/video_stub.dart';
import 'package:ytp_app/services/progress_tracker.dart';

final _t0 = DateTime.utc(2026, 10, 3, 10);

/// A player the test drives: [play] for a while, [seek], [pause].
class _Script {
  _Script(this.async) {
    player.value = const PlayerValue(duration: Duration(seconds: 600));
    tracker = ProgressTracker(
      player: player,
      videoId: 'v',
      onReport: reports.add,
      now: () => _t0.add(async.elapsed),
    );
  }

  final FakeAsync async;
  final player = StubPlayerController();
  final reports = <ProgressReport>[];
  late final ProgressTracker tracker;

  void set({Duration? position, bool? playing, bool? ended}) => player.value =
      player.value.copyWith(position: position, playing: playing, ended: ended);

  /// Plays for [seconds], position ticking 4 times a second like
  /// `timeupdate`.
  void play(int seconds) {
    set(playing: true);
    for (var i = 0; i < seconds * 4; i++) {
      set(position: player.value.position + const Duration(milliseconds: 250));
      async.elapse(const Duration(milliseconds: 250));
    }
  }

  List<int> get positions => [for (final r in reports) r.positionSeconds];
}

void main() {
  test('nothing is reported before 5 s of play', () {
    fakeAsync((async) {
      final s = _Script(async);
      s.play(4);
      s.set(playing: false);
      s.tracker.reportNow();
      expect(s.reports, isEmpty);
      s.play(2);
      s.set(playing: false); // pause reports
      expect(s.positions, [6]);
      expect(s.reports.single.durationSeconds, 600);
      expect(s.reports.single.watchedAt, _t0.add(async.elapsed));
      s.tracker.dispose(report: false);
    });
  });

  test('a heartbeat every 15 s while playing', () {
    fakeAsync((async) {
      final s = _Script(async);
      s.play(46);
      expect(s.positions, [15, 30, 45]);
      s.set(playing: false);
      expect(s.positions.last, 46);
      // Paused: no more heartbeats.
      async.elapse(const Duration(minutes: 1));
      expect(s.reports.length, 4);
      s.tracker.dispose(report: false);
    });
  });

  test('a seek reports once it settles and does not count as played', () {
    fakeAsync((async) {
      final s = _Script(async);
      s.play(3);
      s.set(position: const Duration(seconds: 300)); // seek forward
      expect(s.tracker.played, const Duration(seconds: 3));
      // Played 3 s: still under 5 s, so even the seek reports nothing.
      async.elapse(const Duration(seconds: 2));
      expect(s.reports, isEmpty);
      s.play(3);
      s.set(position: const Duration(seconds: 100)); // seek back
      s.set(position: const Duration(seconds: 120)); // and again
      async.elapse(const Duration(milliseconds: 900));
      expect(s.reports, isEmpty);
      async.elapse(const Duration(milliseconds: 200));
      expect(s.positions, [120]);
      s.tracker.dispose(report: false);
    });
  });

  test('the end reports; dispose reports unless told not to', () {
    fakeAsync((async) {
      final s = _Script(async);
      s.play(6);
      s.set(
        position: const Duration(seconds: 600),
        playing: false,
        ended: true,
      );
      expect(s.positions, [600]); // once, not twice
      s.tracker.dispose();
      expect(s.positions, [600, 600]);
      s.tracker.dispose(); // idempotent
      s.tracker.reportNow(); // and silent afterwards
      expect(s.reports.length, 2);
    });
  });

  test('an unknown duration is left out', () {
    fakeAsync((async) {
      final s = _Script(async);
      s.player.value = const PlayerValue();
      s.play(6);
      s.tracker.reportNow();
      expect(s.reports.last.durationSeconds, isNull);
      s.tracker.dispose(report: false);
    });
  });
}
