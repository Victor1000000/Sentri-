import 'package:flutter_test/flutter_test.dart';
import 'package:sentri/core/net/api.dart';
import 'package:sentri/core/storage/key_value_store.dart';
import 'package:sentri/features/share/share_controller.dart';

import 'helpers.dart';

ShareController make(FakeApi api, FakeTimers timers, {FakeLocation? loc, MemoryKeyValueStore? store}) => ShareController(
      api: api,
      location: loc ?? FakeLocation(),
      battery: FakeBattery(),
      timers: timers,
      store: store ?? MemoryKeyValueStore(),
    );

void main() {
  test('starts, then sends the position on a schedule until stopped', () async {
    final api = FakeApi();
    final timers = FakeTimers();
    final c = make(api, timers);
    expect(await c.start(['c1']), ShareStartOutcome.started);
    expect(c.active?.id, 'share-1');
    await timers.advance(const Duration(seconds: 5));
    await timers.advance(const Duration(seconds: 15));
    expect(api.shareUpdates.length, greaterThanOrEqualTo(2));
    await c.stop();
    expect(c.active, isNull);
    final n = api.shareUpdates.length;
    await timers.advance(const Duration(minutes: 2));
    expect(api.shareUpdates.length, n);
    expect(api.shareCalls, ['start', 'stop']);
  });

  test('reports being offline and unreachable contacts without pretending it started', () async {
    final api = FakeApi()..unreachable = true;
    final c = make(api, FakeTimers());
    expect(await c.start(['c1']), ShareStartOutcome.offline);
    expect(c.active, isNull);
    api
      ..unreachable = false
      ..noneReachable = 'x';
    expect(await c.start(['c1']), ShareStartOutcome.noneReachable);
  });

  test('a stop made offline stops sending at once and is retried until the server confirms', () async {
    final api = FakeApi();
    final timers = FakeTimers();
    final c = make(api, timers);
    await c.start(['c1']);
    api.unreachable = true;
    await c.stop();
    expect(c.active, isNull);
    expect(c.stopPending, isTrue);
    api.unreachable = false;
    await timers.advance(const Duration(seconds: 10));
    expect(c.stopPending, isFalse);
    expect(api.shareCalls.last, 'stop');
  });

  test('ends by itself when the server says the share is over', () async {
    final api = FakeApi();
    final timers = FakeTimers();
    final c = make(api, timers);
    await c.start(['c1']);
    api.shareUpdateError = ApiHttpError(404, 'not_found');
    await timers.advance(const Duration(seconds: 5));
    expect(c.active, isNull);
  });

  test('picks up a running share after a restart', () async {
    final api = FakeApi()..sharesNow = [ShareInfo(id: 's9', expiresAt: DateTime.utc(2026, 10, 13, 20), contactIds: const ['c1'])];
    final c = make(api, FakeTimers());
    await c.resume();
    expect(c.active?.id, 's9');
  });
}
