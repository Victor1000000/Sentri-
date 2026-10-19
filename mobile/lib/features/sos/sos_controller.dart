import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/net/api.dart';
import '../../core/storage/key_value_store.dart';
import '../../core/timers.dart';
import '../battery/battery.dart';
import '../location/location.dart';
import 'local_pin_vault.dart';

/// What the user's screen should show. After a DURESS PIN this reports [idle] on purpose, so a
/// watcher sees exactly what a real cancel looks like while the alert keeps going silently.
enum SosPhase { idle, countdown, active, acknowledged }

enum PinUiResult { cancelled, wrong, locked }

class LocalContact {
  const LocalContact({required this.phone, required this.locale});
  final String phone;
  final String locale;
  Map<String, String> toJson() => {'p': phone, 'l': locale};
  factory LocalContact.fromJson(Map<String, dynamic> j) => LocalContact(phone: j['p'] as String, locale: j['l'] as String);
}

/// Contacts are also kept on the phone, so the contacts screen works with no data.
class ContactStore {
  ContactStore(this._store);
  final KeyValueStore _store;
  static const _k = 'contacts.v1';

  Future<List<LocalContact>> load() async {
    final raw = await _store.read(_k);
    if (raw == null) return const [];
    return [for (final j in jsonDecode(raw) as List<dynamic>) LocalContact.fromJson(j as Map<String, dynamic>)];
  }

  Future<void> save(List<LocalContact> c) => _store.write(_k, jsonEncode([for (final x in c) x.toJson()]));
}

class SosConfig {
  const SosConfig({
    this.cancelWindow = const Duration(seconds: 5),
    this.firstFixTimeout = const Duration(seconds: 2),
    this.fixTimeout = const Duration(seconds: 8),
    this.startRetry = const Duration(seconds: 10),
    this.locationFailuresBeforeWaiting = 3,
    this.pinRetry = const Duration(seconds: 5),
    this.pinRetries = 12,
  });
  final Duration cancelWindow;
  final Duration firstFixTimeout;
  final Duration fixTimeout;

  final Duration startRetry;
  final int locationFailuresBeforeWaiting;
  final Duration pinRetry;
  final int pinRetries;
}

bool _no() => false;
bool _yes() => true;

/// The phone-side alert state machine.
///
///   idle -> countdown (5 s, PIN pad) -> active -> acknowledged
///
/// The alert is started on the server immediately (the server runs the same 5 s window), so if the
/// phone is taken or dies a moment later, the alert still goes out. If the server can't be reached,
/// the alert is kept on the phone and retried every few seconds (and at once when a connection
/// returns) until the server has it. Nothing is ever sent by SMS: contacts are alerted inside the app.
///
/// Every async continuation checks `epoch`, so a late response from an earlier alert can never
/// touch a newer one.
class SosController extends ChangeNotifier {
  SosController({
    required this.api,
    required this.vault,
    required this.location,
    required this.battery,
    required this.timers,
    this.pending,
    this.dataSaver = _no,
    this.config = const SosConfig(),
  });

  final SentriApi api;
  final LocalPinVault vault;
  final LocationSource location;
  final BatterySource battery;
  final Timers timers;

  /// Where an alert that has not reached the server yet is remembered, so it survives the app or phone restarting.
  final KeyValueStore? pending;
  final bool Function() dataSaver;
  final SosConfig config;

  SosPhase _s = SosPhase.idle;
  bool _duress = false;
  String? _duressPin;
  int _epoch = 0;
  String _trigger = 'floating';
  final Map<int, String> _sosIds = {};
  bool _serverOk = false;
  GeoFix? _lastGeo;
  DateTime? _windowEndsAt;
  Future<void>? _startFuture;
  Cancelable? _windowTimer, _trackTimer, _startRetryTimer;
  bool _waiting = false;
  int _locFailures = 0;

  // ---- what the UI sees ----
  SosPhase get phase => _duress ? SosPhase.idle : _s;
  DateTime? get windowEndsAt => _windowEndsAt;
  bool get serverConfirmed => _serverOk;

  /// The latest position fix of the running alert, used to find the police near it.
  GeoFix? get lastGeo => _lastGeo;

  /// "No connection: your alert is saved and will go out the moment you are online". Hidden after a duress PIN.
  bool get offlineQueued => !_duress && _waiting;

  /// True while an alert is running that the screen is not showing (duress). The tracker keeps going.
  bool get silentAlertRunning => _duress && _s != SosPhase.idle;

  // ---- trigger ----

  /// Starts an alert. Safe to call again while one is running (it is ignored).
  Future<void> trigger(String type) async {
    if (_s != SosPhase.idle) return;
    final epoch = ++_epoch;
    _s = SosPhase.countdown;
    _duress = false;
    _duressPin = null;
    _trigger = type;
    _serverOk = false;
    _waiting = false;
    _locFailures = 0;
    _lastGeo = null;
    _windowEndsAt = timers.now().add(config.cancelWindow);
    _windowTimer = timers.once(config.cancelWindow, () => _onWindowEnd(epoch));
    unawaited(_savePending());
    notifyListeners();
    _startFuture = _startServer(epoch);
    await _startFuture;
  }

  Future<void> _startServer(int epoch) async {
    final geo = await location.fix(highAccuracy: true, timeout: config.firstFixTimeout) ?? await location.lastKnown();
    if (epoch != _epoch) return;
    if (geo != null) _lastGeo = geo;
    await _tryStart(epoch);
  }

  Future<void> _tryStart(int epoch) async {
    if (epoch != _epoch || _serverOk) return;
    try {
      final r = await api.startSos(trigger: _trigger, geo: _lastGeo);
      _sosIds[epoch] = r.sosId; // recorded even if the user has cancelled meanwhile
      if (epoch != _epoch) return;
      _serverOk = true;
      _waiting = false;
      unawaited(_deletePending());
      if (_duress && _duressPin != null) unawaited(_syncPin(epoch, null, _duressPin!, config.pinRetries));
      notifyListeners();
    } catch (_) {
      // Unreachable, 429, 5xx, auth trouble, even a garbled reply: keep trying, and keep the alert on the phone meanwhile.
      _retryStartLater(epoch);
    }
  }

  void _retryStartLater(int epoch) {
    if (epoch != _epoch) return;
    _startRetryTimer?.cancel();
    _startRetryTimer = timers.once(config.startRetry, () {
      _startFuture = _tryStart(epoch);
    });
  }

  void _onWindowEnd(int epoch) {
    if (epoch != _epoch || _s != SosPhase.countdown) return;
    _s = SosPhase.active;
    notifyListeners();
    unawaited(_scheduleTrack(epoch));
    if (!_serverOk) {
      _waiting = true;
      notifyListeners();
    }
  }

  // ---- tracking ----

  Future<int> _batteryLevel() async {
    try {
      return await battery.level();
    } catch (_) {
      return 50;
    }
  }

  Future<void> _scheduleTrack(int epoch) async {
    final level = await _batteryLevel();
    if (epoch != _epoch || _s != SosPhase.active) return;
    final plan = locationPlan(batteryPct: level, dataSaver: dataSaver());
    _trackTimer = timers.once(plan.interval, () => unawaited(_trackTick(epoch, plan)));
  }

  Future<void> _trackTick(int epoch, LocationPlan plan) async {
    if (epoch != _epoch || _s != SosPhase.active) return;
    final fix = await location.fix(highAccuracy: plan.highAccuracy, timeout: config.fixTimeout);
    if (epoch != _epoch || _s != SosPhase.active) return;
    if (fix != null) _lastGeo = fix;

    final id = _sosIds[epoch];
    final geo = _lastGeo;
    if (id != null && geo != null) {
      try {
        final state = await api.sendLocation(id, geo);
        if (epoch != _epoch) return;
        _locFailures = 0;
        if (_waiting && _serverOk) {
          _waiting = false; // data is back, the server is alerting again
          notifyListeners();
        }
        if (state == 'acknowledged') {
          _onAcknowledged();
          return;
        }
      } on ApiUnreachable {
        if (epoch != _epoch) return;
        _locFailures++;
        _noteFailure();
      } on ApiHttpError catch (e) {
        if (epoch != _epoch) return;
        if (e.status == 404) {
          _resetToIdle(); // the server says this alert is over
          return;
        }
        _locFailures++;
        _noteFailure();
      } catch (_) {
        // Anything unexpected must not break the loop: count it as a failure and carry on.
        if (epoch != _epoch) return;
        _locFailures++;
        _noteFailure();
      }
    }
    unawaited(_scheduleTrack(epoch));
  }

  void _onAcknowledged() {
    _cancelTimers();
    _waiting = false;
    _s = SosPhase.acknowledged;
    notifyListeners();
  }

  // ---- no connection ----

  void _noteFailure() {
    if (_locFailures >= config.locationFailuresBeforeWaiting && !_waiting) {
      _waiting = true;
      notifyListeners();
    }
  }

  /// Call when the phone gets a connection back. Sends a waiting alert at once instead of at the next retry.
  void networkRestored() {
    if (_s == SosPhase.idle) return;
    final epoch = _epoch;
    if (!_serverOk) {
      _startRetryTimer?.cancel();
      _startFuture = _tryStart(epoch);
    }
    if (_s == SosPhase.active) {
      _trackTimer?.cancel();
      unawaited(_trackTick(epoch, locationPlan(batteryPct: 50, dataSaver: dataSaver())));
    }
  }

  // ---- remembered alert ----

  static const _pendingKey = 'sos.pending.v1';

  Future<void> _savePending() async {
    final store = pending;
    if (store == null) return;
    try {
      await store.write(_pendingKey, jsonEncode({'t': _trigger, 'at': timers.now().millisecondsSinceEpoch}));
    } catch (_) {}
  }

  Future<void> _deletePending() async {
    try {
      await pending?.delete(_pendingKey);
    } catch (_) {}
  }

  /// If the phone restarted (or the app was killed) while an alert had not reached the server, send it now.
  /// It skips the cancel window: the person has had their chance, and a late alert is better than none.
  Future<void> resumePending() async {
    final store = pending;
    if (store == null || _s != SosPhase.idle) return;
    String? raw;
    try {
      raw = await store.read(_pendingKey);
    } catch (_) {}
    if (raw == null) return;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final age = timers.now().difference(DateTime.fromMillisecondsSinceEpoch(j['at'] as int));
      if (age > const Duration(minutes: 20)) return unawaited(_deletePending());
      final epoch = ++_epoch;
      _s = SosPhase.active;
      _duress = false;
      _trigger = j['t'] as String? ?? 'floating';
      _serverOk = false;
      _waiting = true;
      _locFailures = 0;
      _lastGeo = await location.lastKnown();
      notifyListeners();
      unawaited(_scheduleTrack(epoch));
      _startFuture = _tryStart(epoch);
      await _startFuture;
    } catch (_) {
      unawaited(_deletePending());
    }
  }

  // ---- PIN ----

  /// Checks the PIN on the phone (so it works with no data) and tells the server.
  /// A cancel PIN and a duress PIN both return [PinUiResult.cancelled]: they must look identical.
  Future<PinUiResult> submitPin(String pin) async {
    if (_s == SosPhase.idle) return PinUiResult.cancelled;
    final epoch = _epoch;
    final decision = await vault.evaluate(pin, timers.now());
    if (epoch != _epoch || _s == SosPhase.idle) return PinUiResult.cancelled;

    switch (decision) {
      case PinDecision.locked:
        return PinUiResult.locked;
      case PinDecision.wrong:
        return PinUiResult.wrong;
      case PinDecision.cancel:
        final startFuture = _startFuture;
        _resetToIdle();
        unawaited(_syncPin(epoch, startFuture, pin, config.pinRetries));
        return PinUiResult.cancelled;
      case PinDecision.duress:
        _duress = true;
        _duressPin = pin;
        unawaited(_syncPin(epoch, _startFuture, pin, config.pinRetries));
        notifyListeners();
        return PinUiResult.cancelled;
    }
  }

  /// Delivers the PIN to the server, retrying while offline. If the alert's id is unknown (the
  /// start request may have reached the server without the reply reaching us) the server resolves
  /// "the user's current alert" itself.
  Future<void> _syncPin(int epoch, Future<void>? startFuture, String pin, int retriesLeft) async {
    if (startFuture != null) {
      try {
        await startFuture;
      } catch (_) {}
    }
    try {
      await api.submitPin(_sosIds[epoch], pin);
    } on ApiUnreachable {
      if (retriesLeft > 0) timers.once(config.pinRetry, () => unawaited(_syncPin(epoch, null, pin, retriesLeft - 1)));
    } on ApiHttpError {
      // 404: nothing live on the server, so nothing to cancel.
    } catch (_) {
      // A garbled reply: nothing more to do.
    }
  }

  /// "I'm safe" after a contact responded.
  void dismiss() {
    if (_s == SosPhase.acknowledged) _resetToIdle();
  }

  // ---- teardown ----

  void _cancelTimers() {
    _windowTimer?.cancel();
    _trackTimer?.cancel();
    _startRetryTimer?.cancel();
  }

  void _resetToIdle() {
    _epoch++;
    _cancelTimers();
    _s = SosPhase.idle;
    _duress = false;
    _duressPin = null;
    _waiting = false;
    _serverOk = false;
    _windowEndsAt = null;
    unawaited(_deletePending());
    notifyListeners();
  }

  @override
  void dispose() {
    _cancelTimers();
    super.dispose();
  }
}
