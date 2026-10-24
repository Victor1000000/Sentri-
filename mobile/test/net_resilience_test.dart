import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sentri/core/net/api.dart';
import 'package:sentri/core/storage/key_value_store.dart';

/// A pretend server. [handle] gets the request and how many times that path has been asked so far (1 for the first).
class _Server {
  _Server(this.handle);
  final Future<http.Response> Function(http.Request req, int n) handle;
  final calls = <String, int>{};

  http.Client client() => MockClient((req) {
        final n = calls[req.url.path] = (calls[req.url.path] ?? 0) + 1;
        return handle(req, n);
      });
}

const _json = {'content-type': 'application/json'};
const _late = Duration(milliseconds: 300); // longer than any timeout below, so the request "gets no answer"
final _fix = GeoFix(lat: 6.5, lon: 3.4, accuracyM: 10, at: DateTime.utc(2026, 10, 20));

Session _signedIn() => Session(MemoryKeyValueStore())
  ..accessToken = 'a'
  ..refreshToken = 'r'
  ..deviceId = 'd';

HttpSentriApi _api(
  _Server srv, {
  Session? session,
  Duration wakeBudget = const Duration(seconds: 2),
  void Function()? onExpired,
}) =>
    HttpSentriApi(
      baseUrl: 'https://api.example.com',
      session: session ?? Session(MemoryKeyValueStore()),
      client: srv.client(),
      timeout: const Duration(milliseconds: 100),
      patientTimeout: const Duration(milliseconds: 100),
      wakeBudget: wakeBudget,
      wakeProbe: const Duration(milliseconds: 100),
      wakePause: const Duration(milliseconds: 5),
      onSessionExpired: onExpired,
    );

void main() {
  group('a sleeping server', () {
    test('an ordinary request waits for it to wake, then goes through', () async {
      final srv = _Server((req, n) async {
        if (req.url.path == '/healthz') return http.Response('{"ok":true}', 200);
        if (n == 1) await Future<void>.delayed(_late); // the first try gets no answer in time
        return http.Response('{"ok":true}', 202, headers: _json);
      });
      final r = await _api(srv).requestOtp('+2348031234567');
      expect(r.telegramUrl, isNull);
      expect(srv.calls['/healthz'], 1);
      expect(srv.calls['/v1/auth/otp/request'], 2);
    });

    test('the platform\'s "not ready" answer is treated the same way', () async {
      final srv = _Server((req, n) async {
        if (req.url.path == '/healthz') return http.Response('{"ok":true}', 200);
        return n == 1 ? http.Response('starting', 503) : http.Response('{"ok":true}', 202, headers: _json);
      });
      await _api(srv).requestOtp('+2348031234567');
      expect(srv.calls['/v1/auth/otp/request'], 2);
    });

    test('says it is waking while it waits, and stops saying so afterwards', () async {
      final srv = _Server((req, n) async {
        if (req.url.path == '/healthz') return http.Response('{"ok":true}', 200);
        if (n == 1) await Future<void>.delayed(_late);
        return http.Response('{"ok":true}', 202, headers: _json);
      });
      final api = _api(srv);
      final seen = <bool>[];
      api.waking.addListener(() => seen.add(api.waking.value));
      await api.requestOtp('+2348031234567');
      expect(seen, [true, false]);
      expect(api.waking.value, isFalse);
    });

    test('gives up when the server never wakes, and reports it as unreachable', () async {
      final srv = _Server((req, n) async {
        await Future<void>.delayed(_late);
        return http.Response('{}', 200);
      });
      final api = _api(srv, wakeBudget: const Duration(milliseconds: 300));
      await expectLater(api.requestOtp('+2348031234567'), throwsA(isA<ApiUnreachable>()));
      expect(api.waking.value, isFalse);
    });

    test('no connection at all is reported at once, without waiting', () async {
      final srv = _Server((req, n) async => throw http.ClientException('offline'));
      await expectLater(_api(srv).requestOtp('+2348031234567'), throwsA(isA<ApiUnreachable>()));
      expect(srv.calls['/healthz'], isNull);
      expect(srv.calls['/v1/auth/otp/request'], 1);
    });

    test('an alert or a location update never waits: it fails fast so the phone can keep it and retry', () async {
      final srv = _Server((req, n) async {
        await Future<void>.delayed(_late);
        return http.Response('{}', 200);
      });
      await expectLater(_api(srv).sendLocation('abc', _fix), throwsA(isA<ApiUnreachable>()));
      expect(srv.calls['/healthz'], isNull);
      expect(srv.calls['/v1/sos/abc/location'], 1);
    });

    test('prewarm never throws, even when the server stays down', () async {
      final srv = _Server((req, n) async => throw http.ClientException('down'));
      await _api(srv, wakeBudget: const Duration(milliseconds: 50)).prewarm();
    });
  });

  group('a session the server has forgotten', () {
    Future<http.Response> forgets(http.Request req, int n) async => http.Response('{"error":"unauthorized"}', 401, headers: _json);

    test('signs the person out, once, so sign-in can start again', () async {
      final session = _signedIn();
      var expired = 0;
      final api = _api(_Server(forgets), session: session, onExpired: () => expired++);
      await expectLater(api.decideInvite('c1', accept: true), throwsA(isA<ApiHttpError>().having((e) => e.status, 'status', 401)));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(expired, 1);
      expect(session.signedIn, isFalse);
    });

    test('is not signed out just because the session could not be checked', () async {
      final session = _signedIn();
      var expired = 0;
      final srv = _Server((req, n) async {
        if (req.url.path == '/healthz') return http.Response('{"ok":true}', 200);
        if (req.url.path == '/v1/auth/refresh') return http.Response('oops', 500);
        return http.Response('{"error":"unauthorized"}', 401, headers: _json);
      });
      final api = _api(srv, session: session, onExpired: () => expired++);
      await expectLater(api.decideInvite('c1', accept: true), throwsA(isA<ApiUnreachable>()));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(expired, 0);
      expect(session.signedIn, isTrue);
    });

    test('an emergency request never signs the person out', () async {
      final session = _signedIn();
      var expired = 0;
      final api = _api(_Server(forgets), session: session, onExpired: () => expired++);
      await expectLater(api.submitPin('abc', '1234'), throwsA(isA<ApiHttpError>().having((e) => e.status, 'status', 401)));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(expired, 0);
      expect(session.signedIn, isTrue);
    });

    test('a good refresh quietly replaces the tokens and the request goes through', () async {
      final session = _signedIn();
      final srv = _Server((req, n) async {
        if (req.url.path == '/v1/auth/refresh') {
          return http.Response('{"accessToken":"a2","refreshToken":"r2"}', 200, headers: _json);
        }
        return n == 1 ? http.Response('{"error":"unauthorized"}', 401, headers: _json) : http.Response('{}', 200, headers: _json);
      });
      var expired = 0;
      final api = _api(srv, session: session, onExpired: () => expired++);
      await api.decideInvite('c1', accept: true);
      expect(session.accessToken, 'a2');
      expect(session.refreshToken, 'r2');
      expect(expired, 0);
      expect(srv.calls['/v1/invites/c1'], 2);
    });
  });
}
