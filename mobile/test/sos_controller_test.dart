import 'package:flutter_test/flutter_test.dart';
import 'package:sentri/core/net/api.dart';
import 'package:sentri/features/sos/sos_controller.dart';

import 'helpers.dart';

void main() {
  group('cancel window and PINs', () {
    test('cancel PIN during the window: phase goes idle, server is told, nothing else is sent', () async {
      final r = await Rig.create();
      await r.sos.trigger('shake');
      expect(r.sos.phase, SosPhase.countdown);
      expect(r.api.startCalls, 1);

      await r.timers.advance(const Duration(seconds: 2));
      expect(await r.sos.submitPin('1234'), PinUiResult.cancelled);
      expect(r.sos.phase, SosPhase.idle);
      await settle();
      expect(r.api.pinCalls, [(id: 'sos-1', pin: '1234')]);

      await r.timers.advance(const Duration(minutes: 5));
      expect(r.api.locations, isEmpty);
    });

    test('a second trigger while one is running is ignored', () async {
      final r = await Rig.create();
      await r.sos.trigger('shake');
      await r.sos.trigger('volume');
      expect(r.api.startCalls, 1);
    });

    test('wrong PIN keeps the alert; five wrong PINs lock entry (even for the right PIN) until the lockout ends', () async {
      final r = await Rig.create();
      await r.sos.trigger('shake');
      for (var i = 0; i < 4; i++) {
        expect(await r.sos.submitPin('9999'), PinUiResult.wrong);
      }
      expect(await r.sos.submitPin('9999'), PinUiResult.locked);
      expect(await r.sos.submitPin('1234'), PinUiResult.locked);
      expect(r.sos.phase, isNot(SosPhase.idle));

      await r.timers.advance(const Duration(minutes: 5, seconds: 1));
      expect(await r.sos.submitPin('1234'), PinUiResult.cancelled);
      expect(r.sos.phase, SosPhase.idle);
    });

    test('duress PIN looks exactly like a cancel but the alert keeps running silently', () async {
      final r = await Rig.create();
      await r.sos.trigger('shake');
      await r.timers.advance(const Duration(seconds: 5));
      expect(r.sos.phase, SosPhase.active);

      expect(await r.sos.submitPin('4321'), PinUiResult.cancelled);
      expect(r.sos.phase, SosPhase.idle); // what a watcher sees
      expect(r.sos.silentAlertRunning, isTrue);
      expect(r.sos.offlineQueued, isFalse); // never leaks through the UI either
      await settle();
      expect(r.api.pinCalls.single.pin, '4321'); // the server is told so it can flag the alert

      await r.timers.advance(const Duration(seconds: 25));
      expect(r.api.locations, isNotEmpty); // tracking continues

      // A new trigger is ignored (an alert is already running) rather than restarting the screen.
      await r.sos.trigger('shake');
      expect(r.api.startCalls, 1);
    });

    test('the real cancel PIN still ends a silent duress alert (hidden PIN entry on the home screen)', () async {
      final r = await Rig.create();
      await r.sos.trigger('shake');
      await r.timers.advance(const Duration(seconds: 5));
      await r.sos.submitPin('4321');
      expect(r.sos.silentAlertRunning, isTrue);
      await r.sos.submitPin('1234');
      expect(r.sos.silentAlertRunning, isFalse);
      final before = r.api.locations.length;
      await r.timers.advance(const Duration(minutes: 2));
      expect(r.api.locations.length, before);
    });
  });

  group('online alert', () {
    test('after the window it reports location on the adaptive schedule', () async {
      final r = await Rig.create();
      await r.sos.trigger('shake');
      await r.timers.advance(const Duration(seconds: 5));
      expect(r.sos.phase, SosPhase.active);
      await r.timers.advance(const Duration(seconds: 10));
      expect(r.api.locations, hasLength(1));
      await r.timers.advance(const Duration(seconds: 10));
      expect(r.api.locations, hasLength(2));
    });

    test('backs off when the battery is low and in data-saver mode', () async {
      final low = await Rig.create();
      low.battery.pct = 10;
      await low.sos.trigger('shake');
      await low.timers.advance(const Duration(seconds: 5 + 40));
      expect(low.api.locations, hasLength(1)); // every 40 s, not 10 s

      final saver = await Rig.create(dataSaver: true);
      await saver.sos.trigger('shake');
      await saver.timers.advance(const Duration(seconds: 5 + 20));
      expect(saver.api.locations, hasLength(1)); // every 20 s
    });

    test('a contact responding stops the alert and the phone shows it', () async {
      final r = await Rig.create();
      await r.sos.trigger('shake');
      await r.timers.advance(const Duration(seconds: 5));
      r.api.locationState = 'acknowledged';
      await r.timers.advance(const Duration(seconds: 10));
      expect(r.sos.phase, SosPhase.acknowledged);

      final sent = r.api.locations.length;
      await r.timers.advance(const Duration(minutes: 5));
      expect(r.api.locations.length, sent); // tracking stopped
      r.sos.dismiss();
      expect(r.sos.phase, SosPhase.idle);
    });

    test('the server saying the alert is over (404) returns the phone to idle', () async {
      final r = await Rig.create();
      await r.sos.trigger('shake');
      await r.timers.advance(const Duration(seconds: 5));
      r.api.locationError = ApiHttpError(404, 'not_found');
      await r.timers.advance(const Duration(seconds: 10));
      expect(r.sos.phase, SosPhase.idle);
    });
  });

  group('no connection', () {
    test('the alert is kept and retried every 10 seconds, the screen says it is saved, and it goes out the moment data returns', () async {
      final r = await Rig.create();
      r.api.unreachable = true;
      await r.sos.trigger('shake');
      expect(r.sos.offlineQueued, isFalse); // still inside the cancel window
      await r.timers.advance(const Duration(seconds: 5));
      expect(r.sos.offlineQueued, isTrue);
      await r.timers.advance(const Duration(seconds: 30));
      expect(r.api.startCalls, greaterThanOrEqualTo(4));
      expect(r.sos.serverConfirmed, isFalse);

      r.api.unreachable = false;
      r.sos.networkRestored(); // connectivity event: no waiting for the next retry
      await settle();
      expect(r.sos.serverConfirmed, isTrue);
      expect(r.sos.offlineQueued, isFalse);
    });

    test('data returning on its own is picked up by the next retry', () async {
      final r = await Rig.create();
      r.api.unreachable = true;
      await r.sos.trigger('shake');
      await r.timers.advance(const Duration(seconds: 12));
      r.api.unreachable = false;
      await r.timers.advance(const Duration(seconds: 10));
      expect(r.sos.serverConfirmed, isTrue);
      expect(r.sos.offlineQueued, isFalse);
    });

    test('if data drops DURING an alert, three failed location updates show the saved-offline notice', () async {
      final r = await Rig.create();
      await r.sos.trigger('shake');
      await r.timers.advance(const Duration(seconds: 5));
      r.api.unreachable = true;
      await r.timers.advance(const Duration(seconds: 20));
      expect(r.sos.offlineQueued, isFalse); // two failures so far
      await r.timers.advance(const Duration(seconds: 10));
      expect(r.sos.offlineQueued, isTrue);
      r.api.unreachable = false;
      await r.timers.advance(const Duration(seconds: 15));
      expect(r.sos.offlineQueued, isFalse);
    });

    test('duress offline: nothing shows on screen and the duress PIN reaches the server once it is back', () async {
      final r = await Rig.create();
      r.api.unreachable = true;
      await r.sos.trigger('shake');
      await r.timers.advance(const Duration(seconds: 1));
      expect(await r.sos.submitPin('4321'), PinUiResult.cancelled);
      await r.timers.advance(const Duration(seconds: 10));
      expect(r.sos.offlineQueued, isFalse); // hidden from the screen

      r.api.unreachable = false;
      await r.timers.advance(const Duration(seconds: 15));
      expect(r.api.pinCalls.any((c) => c.pin == '4321'), isTrue);
    });

    test('cancelling while offline still reaches the server later, even without knowing the alert id', () async {
      final r = await Rig.create();
      r.api.unreachable = true;
      await r.sos.trigger('shake'); // start request failed, but it may still have reached the server
      expect(await r.sos.submitPin('1234'), PinUiResult.cancelled);

      r.api.unreachable = false;
      await r.timers.advance(const Duration(seconds: 6));
      expect(r.api.pinCalls, [(id: null, pin: '1234')]); // "my current alert"
    });
  });

  group('alert kept on the phone', () {
    test('an alert that never reached the server survives a restart and is sent without a cancel window', () async {
      final r = await Rig.create();
      r.api.unreachable = true;
      await r.sos.trigger('volume');
      await r.timers.advance(const Duration(seconds: 6));
      expect(await r.pending.read('sos.pending.v1'), isNotNull);

      // The phone restarts: a new controller over the same storage.
      final r2 = await Rig.create(pending: r.pending);
      r2.api.unreachable = false;
      await r2.sos.resumePending();
      expect(r2.api.startCalls, 1);
      expect(r2.sos.serverConfirmed, isTrue);
      expect(r2.sos.phase, SosPhase.active);
      expect(await r2.pending.read('sos.pending.v1'), isNull);
    });

    test('once the server has it, nothing is kept; a cancel clears it too; very old ones are dropped', () async {
      final r = await Rig.create();
      await r.sos.trigger('shake');
      await settle();
      expect(await r.pending.read('sos.pending.v1'), isNull);

      final r2 = await Rig.create();
      r2.api.unreachable = true;
      await r2.sos.trigger('shake');
      expect(await r2.sos.submitPin('1234'), PinUiResult.cancelled);
      await settle();
      expect(await r2.pending.read('sos.pending.v1'), isNull);

      final r3 = await Rig.create();
      await r3.pending.write('sos.pending.v1', '{"t":"shake","at":${r3.timers.now().subtract(const Duration(hours: 2)).millisecondsSinceEpoch}}');
      await r3.sos.resumePending();
      expect(r3.api.startCalls, 0);
      expect(r3.sos.phase, SosPhase.idle);
    });
  });
}
