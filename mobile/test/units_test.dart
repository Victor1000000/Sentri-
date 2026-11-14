import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sentri/core/i18n/i18n.dart';
import 'package:sentri/core/net/api.dart';
import 'package:sentri/core/phone.dart';
import 'package:sentri/core/storage/key_value_store.dart';
import 'package:sentri/features/battery/battery.dart';
import 'package:sentri/features/battery/low_battery_alerter.dart';
import 'package:sentri/features/location/location.dart';
import 'package:sentri/features/sos/local_pin_vault.dart';
import 'package:sentri/features/sos/sos_controller.dart';
import 'package:sentri/features/triggers/shake_detector.dart';

import 'helpers.dart';

void main() {
  group('LocalPinVault', () {
    late MemoryKeyValueStore store;
    late LocalPinVault vault;
    final t0 = DateTime.utc(2026, 10, 13, 12);

    setUp(() async {
      store = MemoryKeyValueStore();
      vault = LocalPinVault(store, iterations: 100);
      await vault.save('1234', '4321');
    });

    test('tells cancel, duress and wrong apart', () async {
      expect(await vault.evaluate('1234', t0), PinDecision.cancel);
      expect(await vault.evaluate('4321', t0), PinDecision.duress);
      expect(await vault.evaluate('0000', t0), PinDecision.wrong);
      expect(await vault.evaluate('abcd', t0), PinDecision.wrong);
      expect(await vault.evaluate('', t0), PinDecision.wrong);
    });

    test('never stores a PIN in the clear', () async {
      expect(store.data.values.join(), isNot(contains('1234')));
      expect(store.data.values.join(), isNot(contains('4321')));
    });

    test('rejects bad formats and identical PINs', () async {
      expect(() => vault.save('12', '4321'), throwsArgumentError);
      expect(() => vault.save('1234', '1234'), throwsArgumentError);
      expect(() => vault.save('123456789', '4321'), throwsArgumentError);
    });

    test('the lockout survives restarting the app (it lives in storage, not memory)', () async {
      for (var i = 0; i < 5; i++) {
        await vault.evaluate('9999', t0);
      }
      final restarted = LocalPinVault(store, iterations: 100);
      expect(await restarted.evaluate('1234', t0.add(const Duration(minutes: 1))), PinDecision.locked);
      expect(await restarted.evaluate('1234', t0.add(const Duration(minutes: 6))), PinDecision.cancel);
    });

    test('a correct PIN resets the failure count', () async {
      for (var i = 0; i < 4; i++) {
        await vault.evaluate('9999', t0);
      }
      expect(await vault.evaluate('1234', t0), PinDecision.cancel);
      for (var i = 0; i < 4; i++) {
        expect(await vault.evaluate('9999', t0), PinDecision.wrong);
      }
    });
  });

  group('adaptive location plan', () {
    test('slows down as the battery drains', () {
      expect(locationPlan(batteryPct: 90, dataSaver: false).interval, const Duration(seconds: 10));
      expect(locationPlan(batteryPct: 25, dataSaver: false).interval, const Duration(seconds: 20));
      expect(locationPlan(batteryPct: 12, dataSaver: false).interval, const Duration(seconds: 40));
      expect(locationPlan(batteryPct: 5, dataSaver: false).interval, const Duration(seconds: 60));
    });

    test('drops to medium accuracy below 15%', () {
      expect(locationPlan(batteryPct: 40, dataSaver: false).highAccuracy, isTrue);
      expect(locationPlan(batteryPct: 14, dataSaver: false).highAccuracy, isFalse);
    });

    test('data saver doubles the interval, within limits', () {
      expect(locationPlan(batteryPct: 90, dataSaver: true).interval, const Duration(seconds: 20));
      expect(locationPlan(batteryPct: 5, dataSaver: true).interval, const Duration(seconds: 120));
    });
  });

  group('low battery', () {
    test('fires once at 5%, re-arms after recovering or charging', () {
      final m = LowBatteryMonitor();
      expect(m.shouldAlert(level: 30, charging: false), isFalse);
      expect(m.shouldAlert(level: 5, charging: false), isTrue);
      expect(m.shouldAlert(level: 4, charging: false), isFalse);
      expect(m.shouldAlert(level: 4, charging: true), isFalse);
      expect(m.shouldAlert(level: 5, charging: false), isTrue); // charged, then drained again
    });

    test('sends once, and when there is no data keeps the alert and retries until it gets through', () async {
      final api = FakeApi();
      final a = LowBatteryAlerter(api: api, battery: FakeBattery()..pct = 5, location: FakeLocation(), timers: FakeTimers());
      await a.check();
      expect(api.lowBatteryCalls, 1);
      await a.check();
      expect(api.lowBatteryCalls, 1); // once only

      final api2 = FakeApi()..unreachable = true;
      final b = LowBatteryAlerter(api: api2, battery: FakeBattery()..pct = 5, location: FakeLocation(), timers: FakeTimers());
      await b.check();
      await b.check();
      expect(api2.lowBatteryCalls, 0);
      api2.unreachable = false;
      await b.check();
      expect(api2.lowBatteryCalls, 1);
      await b.check();
      expect(api2.lowBatteryCalls, 1);
    });
  });

  group('phone numbers and contacts', () {
    test('normalises Nigerian formats', () {
      for (final s in ['08031234567', '0803 123 4567', '+2348031234567', '2348031234567', '002348031234567']) {
        expect(normalizePhone(s), '+2348031234567', reason: s);
      }
    });

    test('rejects junk', () {
      for (final s in ['', 'abc', '0803123', '+23480312345678', '123']) {
        expect(normalizePhone(s), isNull, reason: s);
      }
    });

    test('contact list rules: 2 to 10, valid, distinct, not your own number', () {
      const own = '+2348000000000';
      expect(validateContactNumbers(['08031111111'], ownPhone: own).problem, ContactsProblem.tooFewOrMany);
      expect(
        validateContactNumbers(
          ['08031111111', '08032222222', '08033333333', '08034444444', '08035555555', '08036666666', '08037777777', '08038888888', '08039999999', '08031111112', '08032222223'],
          ownPhone: own,
        ).problem,
        ContactsProblem.tooFewOrMany,
      );
      expect(validateContactNumbers(['08031111111', '08032222222'], ownPhone: own).phones, hasLength(2));
      expect(validateContactNumbers(['08031111111', '08032222222', 'nope'], ownPhone: own).problem, ContactsProblem.invalid);
      expect(validateContactNumbers(['08031111111', '08031111111', '08033333333'], ownPhone: own).problem, ContactsProblem.duplicate);
      expect(validateContactNumbers(['08031111111', '08032222222', '08000000000'], ownPhone: own).problem, ContactsProblem.ownNumber);
      expect(
        validateContactNumbers(
          ['08031111111', '08032222222', '08033333333', '08034444444', '08035555555', '08036666666', '08037777777', '08038888888', '08039999999', '08031111112'],
          ownPhone: own,
        ).phones,
        hasLength(10),
      );
      expect(validateContactNumbers(['08031111111', ' ', '08032222222', '08033333333'], ownPhone: own).phones, hasLength(3));
    });
  });

  group('shake detector', () {
    const strong = 30.0; // m/s^2, about 3.1 g
    test('three hard shakes in quick succession trigger once', () {
      final d = ShakeDetector();
      final t = DateTime.utc(2026, 10, 13, 12);
      expect(d.addSample(strong, 0, 0, t), isFalse);
      expect(d.addSample(strong, 0, 0, t.add(const Duration(milliseconds: 300))), isFalse);
      expect(d.addSample(strong, 0, 0, t.add(const Duration(milliseconds: 600))), isTrue);
      // cooldown: an immediate repeat does nothing
      expect(d.addSample(strong, 0, 0, t.add(const Duration(milliseconds: 900))), isFalse);
    });

    test('ordinary movement and slow shakes do not trigger', () {
      final d = ShakeDetector();
      final t = DateTime.utc(2026, 10, 13, 12);
      for (var i = 0; i < 50; i++) {
        expect(d.addSample(0, 0, 11, t.add(Duration(milliseconds: i * 100))), isFalse);
      }
      expect(d.addSample(strong, 0, 0, t.add(const Duration(seconds: 10))), isFalse);
      expect(d.addSample(strong, 0, 0, t.add(const Duration(seconds: 12))), isFalse);
      expect(d.addSample(strong, 0, 0, t.add(const Duration(seconds: 14))), isFalse);
    });

    test('samples closer than the minimum gap count once', () {
      final d = ShakeDetector();
      final t = DateTime.utc(2026, 10, 13, 12);
      for (var i = 0; i < 10; i++) {
        expect(d.addSample(strong, 0, 0, t.add(Duration(milliseconds: i * 20))), isFalse);
      }
    });
  });

  group('travel mode (v41)', () {
    test('classifySpeed puts the bands where a phone can honestly tell them apart', () {
      expect(classifySpeed(0), TravelMode.still);
      expect(classifySpeed(0.4), TravelMode.still);
      expect(classifySpeed(1.2), TravelMode.walk);
      expect(classifySpeed(2.5), TravelMode.walk);
      expect(classifySpeed(4), TravelMode.run);
      expect(classifySpeed(8), TravelMode.ride);
      expect(classifySpeed(25), TravelMode.drive); // 90 km/h
      expect(classifySpeed(60), TravelMode.train);
      expect(classifySpeed(200), TravelMode.flight); // only airspeed reads as flight
    });

    test('metresBetween is a haversine over known ground', () {
      // Lagos island to the mainland, roughly 6.45N 3.40E -> 6.50N 3.40E: about 6.1 km.
      final d = metresBetween(6.45, 3.40, 6.50, 3.40);
      expect(d, greaterThan(5400));
      expect(d, lessThan(6600));
      // A degree of latitude is close enough to 111 km anywhere.
      expect(metresBetween(0, 0, 1, 0), closeTo(111195, 300));
      // Zero distance for the same point, whatever the order.
      expect(metresBetween(6.5, 3.4, 6.5, 3.4), 0);
      expect(metresBetween(6.5, 3.4, 6.45, 3.40), d);
    });

    GeoFix fix(double lat, double lon, double acc, DateTime at) => GeoFix(lat: lat, lon: lon, accuracyM: acc, at: at);

    test('speedBetween divides distance by time and refuses junk', () {
      final a = fix(6.45, 3.40, 10, DateTime.utc(2026, 10, 13, 12, 0, 0));
      final b = fix(6.451, 3.40, 10, DateTime.utc(2026, 10, 13, 12, 0, 15));
      // ~111 m over 15 s is ~7.4 m/s: a runner / easy cyclist.
      final v = speedBetween(a, b)!;
      expect(v, greaterThan(6));
      expect(v, lessThan(9));
      // Too rough to trust: either fix coarse -> no speed.
      expect(speedBetween(fix(6.45, 3.40, 80, a.at), b), isNull);
      expect(speedBetween(a, fix(6.45, 3.40, 80, b.at)), isNull);
      // No honest time gap -> no speed.
      expect(speedBetween(a, fix(6.451, 3.40, 10, a.at)), isNull);
      // Time running backwards -> no speed.
      expect(speedBetween(b, a), isNull);
    });

    test('the watcher needs three agreeing readings before it flips', () {
      final w = TravelWatcher();
      expect(w.mode, TravelMode.still);
      w.feed(1.5); // walk
      expect(w.mode, TravelMode.still); // one reading changes nothing
      w.feed(1.6);
      expect(w.mode, TravelMode.still); // two readings change nothing
      w.feed(1.4);
      expect(w.mode, TravelMode.walk); // three agreeing readings flip it
      // One noisy fix must not flip the chip back.
      w.feed(30);
      expect(w.mode, TravelMode.walk);
      w.feed(28);
      expect(w.mode, TravelMode.walk);
      w.feed(29);
      expect(w.mode, TravelMode.drive);
      // Sliding window: a stray third sample does not stick.
      w.reset();
      w.feed(1.5);
      w.feed(1.5);
      w.feed(30); // pushes walk out of the window
      w.feed(1.5);
      w.feed(1.5);
      w.feed(1.5);
      expect(w.mode, TravelMode.walk);
    });

    test('travelModeFromName round-trips the wire names and refuses junk', () {
      for (final m in TravelMode.values) {
        expect(travelModeFromName(m.name), m);
      }
      expect(travelModeFromName(null), isNull);
      expect(travelModeFromName('hovercraft'), isNull);
      expect(travelModeFromName(''), isNull);
    });
  });

  group('translations', () {
    Future<I18n> load(String code) async {
      final i = I18n(loader: (p) => File(p).readAsString());
      await i.init(code);
      return i;
    }

    Map<String, dynamic> readJson(String code) {
      final raw = File('assets/i18n/$code.json').readAsStringSync();
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    }

    test('every language has every English key, with the same placeholders', () {
      final en = readJson('en');
      for (final lang in supportedLanguages) {
        final t = readJson(lang.code);
        expect(t.keys.toSet(), en.keys.toSet(), reason: lang.code);
        for (final k in en.keys) {
          final ph = RegExp(r'\{\w+\}');
          expect(ph.allMatches(t[k] as String).map((m) => m.group(0)).toList()..sort(),
              ph.allMatches(en[k] as String).map((m) => m.group(0)).toList()..sort(),
              reason: '${lang.code}:$k');
        }
      }
    });

    test('looks up, fills placeholders, and falls back to English then to the key', () async {
      final i = await load('pcm');
      expect(i.t('sos.im_safe'), 'I dey safe');
      expect(i.t('sos.countdown', {'seconds': '3'}), contains('3'));
      expect(i.t('no.such.key'), 'no.such.key');
      await i.setLanguage('xx'); // unknown language
      expect(i.code, 'en');
    });
  });
}
