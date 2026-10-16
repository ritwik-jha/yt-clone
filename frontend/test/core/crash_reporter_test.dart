import 'package:flutter_test/flutter_test.dart';
import 'package:ytp_app/core/crash_reporter.dart';

void main() {
  test('scrubs cookies, bearer tokens, JWTs, and presigned signatures', () {
    const jwt = 'eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxMjMifQ.c2lnbmF0dXJl';
    final out = scrubSecrets(
      'Authorization: Bearer $jwt; Cookie: refresh_token=abc123; '
      'access_token=$jwt '
      'PUT https://b.s3.amazonaws.com/k?X-Amz-Signature=deadbeef&X-Amz-Credential=AKIA%2Fx',
    );
    expect(out, isNot(contains('abc123')));
    expect(out, isNot(contains('deadbeef')));
    expect(out, isNot(contains('AKIA')));
    expect(out, isNot(contains('eyJ')));
    expect(out, contains('refresh_token=<redacted>'));
  });

  test('reportError hands only scrubbed text to the sink', () {
    final seen = <String>[];
    final previous = crashSink;
    crashSink = (m, _) => seen.add(m);
    addTearDown(() => crashSink = previous);
    reportError(Exception('boom access_token=secret'), null);
    expect(seen.single, isNot(contains('secret')));
  });
}
