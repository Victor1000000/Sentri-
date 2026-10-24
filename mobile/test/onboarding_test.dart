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

({OnboardingController c, FakeApi api, List<Uri> opened, AppSettings settings}) _rig({Future<bool> Function(Uri url)? open}) {
  final store = MemoryKeyValueStore();
  final api = FakeApi();
  final opened = <Uri>[];
  final settings = AppSettings(store);
  final c = OnboardingController(
    api: api,
    i18n: I18n(loader: (_) async => '{}'),
    session: Session(store),
    keyStore: store,
    vault: LocalPinVault(store, iterations: 1),
    contacts: ContactStore(store),
    settings: settings,
    bridge: FakeBridge(),
    openLink: open ??
        (url) async {
          opened.add(url);
          return true;
        },
  );
  return (c: c, api: api, opened: opened, settings: settings);
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

    test('a session the server no longer knows sends the person back to sign in, with a clear message', () async {
      final r = _rig();
      r.api.telegramUrl = _bot;
      await r.c.submitPhone('08031234567');
      await r.settings.update(onboarded: true);
      await r.c.sessionExpired();
      expect(r.c.step, OnboardingStep.phone);
      expect(r.c.errorKey, 'auth.session_ended');
      expect(r.c.telegramUrl, isNull);
      expect(r.settings.onboarded, isFalse);
    });

    test('a bad number asks the server for nothing and opens nothing', () async {
      final r = _rig();
      r.api.telegramUrl = _bot;
      await r.c.submitPhone('abc');
      expect(r.c.step, isNot(OnboardingStep.otp));
      expect(r.c.errorKey, 'phone.invalid');
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

  // The server checks every one of these again. Stopping an obvious mistake on the phone saves a round trip and
  // tells the person what is wrong in their own language.
  group('obvious mistakes are stopped before anything is sent', () {
    test('a code shorter than six digits never reaches the server', () async {
      final r = _rig();
      await r.c.submitCode('12345');
      expect(r.c.errorKey, 'otp.format');
      expect(r.api.verifyCalls, 0);
      expect(r.c.busy, isFalse);
    });

    test('a code with letters never reaches the server', () async {
      final r = _rig();
      await r.c.submitCode('12ab56');
      expect(r.c.errorKey, 'otp.format');
      expect(r.api.verifyCalls, 0);
    });

    test('an empty code is refused', () async {
      final r = _rig();
      await r.c.submitCode('   ');
      expect(r.c.errorKey, 'otp.format');
      expect(r.api.verifyCalls, 0);
    });

    test('a good code, typed with spaces round it, is sent as six digits', () async {
      final r = _rig();
      await r.c.submitCode(' 123456 ');
      expect(r.c.errorKey, isNull);
      expect(r.api.verifyCalls, 1);
      expect(r.api.verifyRequests.single.code, '123456');
      expect(r.c.step, OnboardingStep.contacts);
    });

    test('a PIN of three digits is refused and nothing is saved', () async {
      final r = _rig();
      await r.c.submitPins('123', '123');
      expect(r.c.errorKey, 'pins.format');
      expect(r.api.pinsSaved, 0);
    });

    test('a PIN of nine digits is refused', () async {
      final r = _rig();
      await r.c.submitPins('123456789', '123456789');
      expect(r.c.errorKey, 'pins.format');
      expect(r.api.pinsSaved, 0);
    });

    test('a PIN with letters is refused', () async {
      final r = _rig();
      await r.c.submitPins('12ab', '12ab');
      expect(r.c.errorKey, 'pins.format');
      expect(r.api.pinsSaved, 0);
    });

    test('a confirm PIN that does not match is refused', () async {
      final r = _rig();
      await r.c.submitPins('1234', '4321');
      expect(r.c.errorKey, 'pins.mismatch');
      expect(r.api.pinsSaved, 0);
    });

    test('a good PIN is saved on the phone and on the server, then setup moves on', () async {
      final r = _rig();
      await r.c.submitPins('1234', '1234');
      expect(r.c.errorKey, isNull);
      expect(r.api.pinsSaved, 1);
      expect(await r.c.vault.isSet, isTrue);
      expect(r.c.step, OnboardingStep.permissions);
    });

    test('two contacts are refused: at least three are needed', () async {
      final r = _rig();
      await r.c.submitContacts(['08031111111', '08032222222']);
      expect(r.c.errorKey, 'contacts.need_more');
      expect(r.api.contactsSaved, isEmpty);
    });

    test('a contact number that is not a number is refused', () async {
      final r = _rig();
      await r.c.submitContacts(['08031111111', '08032222222', 'not a number']);
      expect(r.c.errorKey, 'contacts.invalid');
      expect(r.api.contactsSaved, isEmpty);
    });

    test('the same number twice is refused', () async {
      final r = _rig();
      await r.c.submitContacts(['08031111111', '08031111111', '08032222222']);
      expect(r.c.errorKey, 'contacts.invalid');
      expect(r.api.contactsSaved, isEmpty);
    });

    test('three different numbers are saved in the international form', () async {
      final r = _rig();
      await r.c.submitContacts(['08031111111', '0803 222 2222', '08033333333']);
      expect(r.c.errorKey, isNull);
      expect(r.api.contactsSaved.single, ['+2348031111111', '+2348032222222', '+2348033333333']);
      expect(r.c.step, OnboardingStep.pins);
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
        ask('{"error":"try_later"}', status: 500),
        throwsA(isA<ApiHttpError>().having((e) => e.status, 'status', 500)),
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
