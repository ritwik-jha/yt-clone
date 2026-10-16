import 'package:flutter_test/flutter_test.dart';
import 'package:ytp_app/core/format.dart';
import 'package:ytp_app/core/validators.dart';

void main() {
  group('password', () {
    test('first failing rule is reported', () {
      expect(Validators.newPassword('Ab1!'), contains('8 characters'));
      expect(Validators.newPassword('abcdefg1!'), contains('uppercase'));
      expect(Validators.newPassword('ABCDEFG1!'), contains('lowercase'));
      expect(Validators.newPassword('Abcdefgh!'), contains('number'));
      expect(Validators.newPassword('Abcdefg12'), contains('special'));
      expect(Validators.newPassword('Abcdef1!'), isNull);
    });
  });

  test('name 2-50 trimmed', () {
    expect(Validators.name(' a '), isNotNull);
    expect(Validators.name('Ada'), isNull);
    expect(Validators.name('x' * 51), isNotNull);
  });

  test('otp is exactly 6 digits', () {
    expect(Validators.otp('12345'), isNotNull);
    expect(Validators.otp('1234567'), isNotNull);
    expect(Validators.otp('12a456'), isNotNull);
    expect(Validators.otp('123456'), isNull);
  });

  test('title 1-100 trimmed; description <= 1000', () {
    expect(Validators.videoTitle('   '), isNotNull);
    expect(Validators.videoTitle('x' * 101), isNotNull);
    expect(Validators.videoTitle(' ok '), isNull);
    expect(Validators.description('x' * 1001), isNotNull);
    expect(Validators.description('x' * 1000), isNull);
  });

  test('email', () {
    expect(Validators.email('nope'), isNotNull);
    expect(Validators.email(' a@b.co '), isNull);
  });

  test('duration + views formatting', () {
    expect(formatDuration(65), '1:05');
    expect(formatDuration(3725), '1:02:05');
    expect(formatViews(1200), '1.2K views');
    expect(formatViews(1), '1 view');
    expect(formatViewsFull(1234), '1,234 views');
    expect(
      timeAgo(DateTime(2026, 1, 1), now: DateTime(2026, 1, 4)),
      '3 days ago',
    );
  });
}
