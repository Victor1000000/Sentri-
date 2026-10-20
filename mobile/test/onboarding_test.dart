import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sentri/core/i18n/i18n.dart';
import 'package:sentri/core/net/api.dart';
import 'package:sentri/core/settings.dart';
import 'package:sentri/core/storage/key_value_store.dart';
import 'package:sentri/features/onboarding/onboarding_controller.dart';
import 'package:sentri/features/sos/local_pin_vault.dart';
import 'package:sentri/features/sos/sos_controller.dart';

import 'helpers.dart';

final _bot = Uri.parse('https://t.me/sentri_login_bot?start=login');

({OnboardingController c, FakeApi api, List<Uri> opened}) _rig({Future<bool> Function(Uri url)? open}) {
  final store = MemoryKeyValueStore();
  final api = FakeApi();
  final opened = <Uri>[];
  final c = OnboardingController(
    api: api,
    i18n: I18n(loader: (_) async => '{}'),
    session: Session(store),
    keyStore: store,
    vault: LocalPinVault(store, iterations: 1),
    contacts: ContactStore(store),
    settings: AppSettings(store),
    bridge: FakeBridge(),
    openLink: open ??
        (url) async {
          opened.add(url);
          return true;
        },
  );
  return (c: c, api: api, opened: opened);
}

void main() {
  group('sign-up with the Telegram bot', () {
    test('goes to the code screen and opens the bot in Telegram', () async {
      final r = _rig();
      r.api.telegramUrl = _bot;
      await r.c.submitPhone('0803 123 4567');
      expect(r.c.step, OnboardingStep.otp);
      expect(r.c.phone, '+2348031234567');
      expect(r.c.telegramUrl, _bot);
      expect(r.opened, [_bot]);
      expect(r.c.errorKey, isNull);
      expect(r.c.busy, isFalse);
      expect(r.api.otpRequests, 1);
    });

    test('still reaches the code screen when Telegram cannot be opened', () async {
      final r = _rig(open: (_) async => throw Exception('no app can open this'));
      r.api.telegramUrl = _bot;
      await r.c.submitPhone('08031234567');
      expect(r.c.step, OnboardingStep.otp);
      expect(r.c.errorKey, isNull);
      expect(r.c.telegramUrl, _bot);
    });

    test('still reaches the code screen when opening the link reports failure', () async {
      final r = _rig(open: (_) async => false);
      r.api.telegramUrl = _bot;
      await r.c.submitPhone('08031234567');
      expect(r.c.step, OnboardingStep.otp);
      expect(r.c.errorKey, isNull);
    });

    test('the Open Telegram button opens the bot again', () async {
      final r = _rig();
      r.api.telegramUrl = _bot;
      await r.c.submitPhone('08031234567');
      await r.c.openTelegram();
      expect(r.opened, [_bot, _bot]);
    });

    test('opening Telegram does nothing when there is no link', () async {
      final r = _rig();
      await r.c.openTelegram();
      expect(r.opened, isEmpty);
    });

    test('going back forgets the link', () async {
      final r = _rig();
      r.api.telegramUrl = _bot;
      await r.c.submitPhone('08031234567');
      r.c.back();
      expect(r.c.step, OnboardingStep.phone);
      expect(r.c.telegramUrl, isNull);
    });

    test('a bad number asks the server for nothing and opens nothing', () async {
      final r = _rig();
      r.api.telegramUrl = _bot;
      await r.c.submitPhone('abc');
      expect(r.c.step, isNot(OnboardingStep.otp));
      expect(r.c.errorKey, 'common.error');
      expect(r.api.otpRequests, 0);
      expect(r.opened, isEmpty);
    });

    test('an unreachable server shows an error and does not open Telegram', () async {
      final r = _rig();
      r.api.telegramUrl = _bot;
      r.api.unreachable = true;
      await r.c.submitPhone('08031234567');
      expect(r.c.step, isNot(OnboardingStep.otp));
      expect(r.c.errorKey, 'common.error');
      expect(r.c.busy, isFalse);
      expect(r.opened, isEmpty);
    });
  });

  group('sign-up with a text message', () {
    test('opens no link and keeps the test code when the server echoes it', () async {
      final r = _rig();
      r.api.devCode = '123456';
      await r.c.submitPhone('08031234567');
      expect(r.c.step, OnboardingStep.otp);
      expect(r.c.telegramUrl, isNull);
      expect(r.c.devCode, '123456');
      expect(r.opened, isEmpty);
    });
  });

  group('requestOtp over HTTP', () {
    Future<OtpRequest> ask(String body, {int status = 202, List<http.Request>? seen}) {
      final api = HttpSentriApi(
        baseUrl: 'https://api.example.com',
        session: Session(MemoryKeyValueStore()),
        client: MockClient((req) async {
          seen?.add(req);
          return http.Response(body, status, headers: {'content-type': 'application/json'});
        }),
      );
      return api.requestOtp('+2348031234567');
    }

    test('sends the number to the right place and accepts a t.me link', () async {
      final seen = <http.Request>[];
      final r = await ask('{"ok":true,"telegramUrl":"https://t.me/sentri_login_bot?start=login"}', seen: seen);
      expect(r.telegramUrl, _bot);
      expect(r.devCode, isNull);
      expect(seen.single.method, 'POST');
      expect(seen.single.url.toString(), 'https://api.example.com/v1/auth/otp/request');
      expect(seen.single.body, contains('+2348031234567'));
    });

    for (final bad in [
      'http://t.me/sentri_login_bot',
      'https://evil.example/sentri_login_bot',
      'https://t.me.evil.example/x',
      'https://evil.example/t.me',
      'https://user@t.me/x',
      'https://t.me:8443/x',
      'tg://resolve?domain=sentri_login_bot',
      'javascript:alert(1)',
      '',
    ]) {
      test('ignores the link "$bad"', () async {
        final r = await ask('{"ok":true,"telegramUrl":"$bad"}');
        expect(r.telegramUrl, isNull);
      });
    }

    test('ignores a link that is not text', () async {
      final r = await ask('{"ok":true,"telegramUrl":123}');
      expect(r.telegramUrl, isNull);
    });

    test('returns the test code in dev echo mode', () async {
      final r = await ask('{"ok":true,"devCode":"123456"}');
      expect(r.devCode, '123456');
      expect(r.telegramUrl, isNull);
    });

    test('copes with an answer that is not an object', () async {
      for (final body in ['oops', '[]', '']) {
        final r = await ask(body);
        expect(r.devCode, isNull);
        expect(r.telegramUrl, isNull);
      }
    });

    test('reports a server error as an error', () async {
      await expectLater(
        ask('{"error":"try_later"}', status: 503),
        throwsA(isA<ApiHttpError>().having((e) => e.status, 'status', 503)),
      );
    });

    test('reports no connection as unreachable', () async {
      final api = HttpSentriApi(
        baseUrl: 'https://api.example.com',
        session: Session(MemoryKeyValueStore()),
        client: MockClient((_) async => throw http.ClientException('offline')),
      );
      await expectLater(api.requestOtp('+2348031234567'), throwsA(isA<ApiUnreachable>()));
    });
  });
}
