import 'dart:async';

import 'package:battery_plus/battery_plus.dart';

/// Battery level as the rest of the app sees it.
abstract class BatterySource {
  /// 0..100
  Future<int> level();
  Future<bool> isCharging();
}

class BatteryPlusSource implements BatterySource {
  final Battery _b = Battery();
  @override
  Future<int> level() => _b.batteryLevel;
  @override
  Future<bool> isCharging() async {
    final s = await _b.batteryState;
    return s == BatteryState.charging || s == BatteryState.full;
  }
}

/// Decides when to send the one-shot "last known location" alert at about 5% battery.
/// It fires once per discharge: it re-arms only after the battery recovers above [rearmAbove]
/// or the phone is plugged in. It never claims live tracking: the message says "last location".
class LowBatteryMonitor {
  LowBatteryMonitor({this.threshold = 5, this.rearmAbove = 15});

  final int threshold;
  final int rearmAbove;
  bool _sent = false;

  /// Returns true exactly when an alert should be sent now.
  bool shouldAlert({required int level, required bool charging}) {
    if (charging || level >= rearmAbove) {
      _sent = false;
      return false;
    }
    if (level <= threshold && !_sent) {
      _sent = true;
      return true;
    }
    return false;
  }
}
