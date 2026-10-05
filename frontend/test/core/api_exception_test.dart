import 'package:flutter_test/flutter_test.dart';
import 'package:ytp_app/core/api_exception.dart';

void main() {
  test('string detail + code', () {
    final e = ApiException.fromResponse(400, {
      'detail': 'Incorrect email or password',
      'code': 'incorrect_credentials',
    });
    expect(e.kind, ApiErrorKind.badRequest);
    expect(e.code, 'incorrect_credentials');
    expect(e.message, 'Incorrect email or password');
    expect(e.fieldErrors, isEmpty);
  });

  test('validation_error maps loc.last and strips the prefix', () {
    final e = ApiException.fromResponse(400, {
      'code': 'validation_error',
      'detail': [
        {
          'type': 'value_error',
          'loc': ['body', 'password'],
          'msg': 'Value error, password must contain a number',
          'input': 'secret',
        },
      ],
    });
    expect(e.fieldErrors, {'password': 'password must contain a number'});
    expect(e.message, 'password must contain a number');
  });

  test('non-JSON body (ALB 502) has no code', () {
    final e = ApiException.fromResponse(502, '<html>Bad gateway</html>');
    expect(e.code, isNull);
    expect(e.kind, ApiErrorKind.server);
  });

  test('status -> kind', () {
    ApiErrorKind k(int s) => ApiException.fromResponse(s, null).kind;
    expect(k(401), ApiErrorKind.unauthorized);
    expect(k(404), ApiErrorKind.notFound);
    expect(k(409), ApiErrorKind.conflict);
    expect(k(429), ApiErrorKind.throttled);
    expect(k(503), ApiErrorKind.unavailable);
    expect(ApiException.fromResponse(503, null).isTransient, isTrue);
  });
}
