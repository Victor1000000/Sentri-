import 'dart:async';

import '../../core/net/api.dart';
import '../../core/timers.dart';
import '../location/location.dart';
import 'battery.dart';

/// Polls the battery and, at about 5%, sends ONE "last known location" alert to the contacts.
/// The alert goes to contacts inside the app. If there is no data it is kept and retried on every poll
/// until it gets through. It never claims to track a phone that has switched off.
class LowBatteryAlerter {
  LowBatteryAlerter({
    required this.api,
    required this.battery,
    required this.location,
    required this.timers,
    LowBatteryMonitor? monitor,
    this.interval = const Duration(seconds: 60),
  }) : monitor = monitor ?? LowBatteryMonitor();

  final SentriApi api;
  final BatterySource battery;
  final LocationSource location;
  final Timers timers;
  final LowBatteryMonitor monitor;
  final Duration interval;

  Cancelable? _t;
  bool _running = false;

  /// An alert that has not reached the server yet. Retried until it does, for about half an hour.
  int _unsent = 0;

  void start() {
    if (_running) return;
    _running = true;
    _schedule();
  }

  void stop() {
    _running = false;
    _t?.cancel();
  }

  void _schedule() {
    _t = timers.once(interval, () async {
      await check();
      if (_running) _schedule();
    });
  }

  /// One poll. Public so tests (and a manual "send now" button) can call it.
  Future<void> check() async {
    int level;
    bool charging;
    try {
      level = await battery.level();
      charging = await battery.isCharging();
    } catch (_) {
      return;
    }
    if (charging || level >= monitor.rearmAbove) _unsent = 0;
    if (monitor.shouldAlert(level: level, charging: charging)) _unsent = 30;
    if (_unsent <= 0) return;
    _unsent--;

    final geo = await location.lastKnown() ?? await location.fix(highAccuracy: false, timeout: const Duration(seconds: 5));
    try {
      await api.lowBattery(geo);
      _unsent = 0;
    } catch (_) {
      // No connection or the server said no: _unsent stays set, so the next poll tries again.
    }
  }
}
