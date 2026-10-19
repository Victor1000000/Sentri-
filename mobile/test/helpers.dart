import 'dart:async';

import 'package:sentri/core/net/api.dart';
import 'package:sentri/core/platform/native_bridge.dart';
import 'package:sentri/core/storage/key_value_store.dart';
import 'package:sentri/core/timers.dart';
import 'package:sentri/features/battery/battery.dart';
import 'package:sentri/features/location/location.dart';
import 'package:sentri/features/sos/local_pin_vault.dart';
import 'package:sentri/features/sos/sos_controller.dart';

/// Lets tests move time forward deterministically.
class FakeTimers implements Timers {
  DateTime _now = DateTime.utc(2026, 10, 13, 12);
  final List<_Job> _jobs = [];

  @override
  DateTime now() => _now;

  @override
  Cancelable once(Duration delay, void Function() fn) {
    final j = _Job(_now.add(delay), fn);
    _jobs.add(j);
    return j;
  }

  int get pendingCount => _jobs.where((j) => !j.cancelled).length;

  /// Runs every job due within [d], in time order, letting async work settle after each.
  Future<void> advance(Duration d) async {
    final target = _now.add(d);
    while (true) {
      final due = _jobs.where((j) => !j.cancelled && !j.ran && !j.at.isAfter(target)).toList()
        ..sort((a, b) => a.at.compareTo(b.at));
      if (due.isEmpty) break;
      final j = due.first;
      j.ran = true;
      if (j.at.isAfter(_now)) _now = j.at;
      j.fn();
      await settle();
    }
    _now = target;
    await settle();
  }
}

class _Job implements Cancelable {
  _Job(this.at, this.fn);
  final DateTime at;
  final void Function() fn;
  bool cancelled = false;
  bool ran = false;
  @override
  void cancel() => cancelled = true;
}

/// Lets pending futures run.
Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class FakeApi implements SentriApi {
  bool unreachable = false;
  String locationState = 'active';
  int startCalls = 0;
  final List<String> pins = [];
  final List<({String? id, String pin})> pinCalls = [];
  final List<({String id, GeoFix geo})> locations = [];
  int lowBatteryCalls = 0;
  String sosId = 'sos-1';

  void _check() {
    if (unreachable) throw ApiUnreachable('offline');
  }

  @override
  Future<SosStartResult> startSos({required String trigger, GeoFix? geo}) async {
    startCalls++;
    _check();
    return SosStartResult(sosId, 'countdown');
  }

  ApiHttpError? locationError;

  @override
  Future<String> sendLocation(String id, GeoFix geo) async {
    _check();
    if (locationError != null) throw locationError!;
    locations.add((id: id, geo: geo));
    return locationState;
  }

  @override
  Future<PinResult> submitPin(String? id, String pin) async {
    _check();
    pinCalls.add((id: id, pin: pin));
    return PinResult.cancelled;
  }

  @override
  Future<void> lowBattery(GeoFix? geo) async {
    _check();
    lowBatteryCalls++;
  }

  Place? place = const Place(street: 'Allen Avenue', area: 'Ikeja', state: 'Lagos', label: 'Allen Avenue, Ikeja, Lagos');
  @override
  Future<Place?> reverseGeocode(double lat, double lon) async {
    _check();
    return place;
  }

  String? devCode;
  int otpRequests = 0;
  @override
  Future<String?> requestOtp(String phone) async {
    otpRequests++;
    return devCode;
  }
  @override
  Future<SignInResult> verifyOtp({
    required String phone,
    required String code,
    required String platform,
    required String publicKey,
    required String boxPublicKey,
    required String locale,
  }) async =>
      const SignInResult(userId: 'u', isNew: true);
  @override
  Future<void> saveContacts(List<({String phone, String locale})> contacts) async {}
  @override
  Future<void> savePins({required String cancelPin, required String duressPin}) async {}
  @override
  Future<void> saveProfile({String? locale, bool? dataSaver, String? name}) async {}
  List<ContactStatus> contactStatuses = const [
    ContactStatus(phone: '+2348031111111', consent: 'accepted'),
    ContactStatus(phone: '+2348032222222', consent: 'pending'),
    ContactStatus(phone: '+2348033333333', consent: 'declined'),
  ];
  @override
  Future<List<ContactStatus>> listContacts() async {
    _check();
    return contactStatuses;
  }

  @override
  Future<void> savePushToken(String token) async {}

  // ---- inbox and sharing ----
  InboxList inboxData = const InboxList();
  @override
  Future<InboxList> inbox() async {
    _check();
    return inboxData;
  }

  @override
  Future<InboxDetail?> inboxItem(String id) async => null;
  @override
  Future<String> respondToAlert(String id) async => 'ok';
  @override
  Future<void> decideInvite(String contactId, {required bool accept}) async {}
  @override
  Future<TestAlertResult> sendTestAlert() async => const TestAlertResult(sent: 1, reachable: 1, total: 3);

  final List<String> shareCalls = [];
  final List<({String id, GeoFix geo})> shareUpdates = [];
  ApiHttpError? shareUpdateError;
  String? noneReachable;
  @override
  Future<ShareStartResult> startShare(List<String> contactIds, {GeoFix? geo, double? hours}) async {
    _check();
    if (noneReachable != null) throw ApiHttpError(422, 'none_reachable');
    shareCalls.add('start');
    return ShareStartResult(id: 'share-1', expiresAt: DateTime.utc(2026, 10, 13, 20), reached: contactIds.length, unreachable: const []);
  }

  @override
  Future<void> updateShare(String id, GeoFix geo) async {
    _check();
    if (shareUpdateError != null) throw shareUpdateError!;
    shareUpdates.add((id: id, geo: geo));
  }

  @override
  Future<void> stopShare(String id) async {
    _check();
    shareCalls.add('stop');
  }

  @override
  Future<DateTime> extendShare(String id, double hours) async {
    _check();
    return DateTime.utc(2026, 10, 13, 21);
  }

  List<ShareInfo> sharesNow = const [];
  @override
  Future<List<ShareInfo>> activeShares() async {
    _check();
    return sharesNow;
  }
}

class FakeLocation implements LocationSource {
  GeoFix? current = GeoFix(lat: 6.5244, lon: 3.3792, accuracyM: 10, at: DateTime.utc(2026, 10, 13, 12));
  @override
  Future<GeoFix?> fix({required bool highAccuracy, required Duration timeout}) async => current;
  @override
  Future<GeoFix?> lastKnown() async => current;
}

class FakeBattery implements BatterySource {
  int pct = 80;
  bool charging = false;
  @override
  Future<int> level() async => pct;
  @override
  Future<bool> isCharging() async => charging;
}

class Rig {
  Rig._(this.api, this.timers, this.sos, this.vault, this.location, this.battery, this.pending);
  final FakeApi api;
  final MemoryKeyValueStore pending;
  final FakeTimers timers;
  final SosController sos;
  final LocalPinVault vault;
  final FakeLocation location;
  final FakeBattery battery;

  static Future<Rig> create({bool dataSaver = false, MemoryKeyValueStore? pending}) async {
    final api = FakeApi();
    pending ??= MemoryKeyValueStore();
    final timers = FakeTimers();
    final location = FakeLocation();
    final battery = FakeBattery();
    // Few iterations: speed matters in tests, the algorithm is the same.
    final vault = LocalPinVault(MemoryKeyValueStore(), iterations: 100);
    await vault.save('1234', '4321');
    final sos = SosController(
      api: api,
      vault: vault,
      location: location,
      battery: battery,
      timers: timers,
      pending: pending,
      dataSaver: () => dataSaver,
    );
    return Rig._(api, timers, sos, vault, location, battery, pending);
  }
}

class FakeBridge implements NativeBridge {
  @override
  void onTrigger(void Function(TriggerType type) handler) {}
  @override
  Future<TriggerType?> takePendingTrigger() async => null;
  @override
  Future<void> startProtection(TriggerSettings settings) async {}
  @override
  Future<void> stopProtection() async {}
  @override
  Future<NativePermissions> permissions() async => const NativePermissions();
  @override
  Future<void> openSettings(String which) async {}
}
