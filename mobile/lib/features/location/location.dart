import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../../core/net/api.dart';

/// How often to ask for a fix, and how precisely, while an alert is running.
class LocationPlan {
  const LocationPlan({required this.interval, required this.highAccuracy});
  final Duration interval;
  final bool highAccuracy;
}

/// Adaptive tracking: report often when the battery is healthy, back off as it drains, and back off
/// further in data-saver mode. The goal is that the phone lasts as long as the emergency does.
LocationPlan locationPlan({required int batteryPct, required bool dataSaver}) {
  int seconds;
  bool high = true;
  if (batteryPct > 30) {
    seconds = 10;
  } else if (batteryPct > 15) {
    seconds = 20;
  } else if (batteryPct > 8) {
    seconds = 40;
    high = false;
  } else {
    seconds = 60;
    high = false;
  }
  if (dataSaver) seconds = (seconds * 2).clamp(20, 120);
  return LocationPlan(interval: Duration(seconds: seconds), highAccuracy: high);
}

/// Where fixes come from. A fake implements this in tests.
abstract class LocationSource {
  /// A fresh fix, or null if none could be had within [timeout].
  Future<GeoFix?> fix({required bool highAccuracy, required Duration timeout});

  /// The OS's cached last fix; instant but possibly old.
  Future<GeoFix?> lastKnown();

  /// Like [fix], but lets the GPS settle and returns the best reading it got. A phone's first reading is often a rough
  /// one from Wi-Fi or mobile towers; the GPS needs a few seconds to do better. For screens where being exact matters
  /// more than being instant (the map). Alerts keep using [fix], which is quick.
  Future<GeoFix?> preciseFix({Duration timeout = const Duration(seconds: 20)}) => fix(highAccuracy: true, timeout: timeout);
}

class GeolocatorSource implements LocationSource {
  @override
  Future<GeoFix?> fix({required bool highAccuracy, required Duration timeout}) async {
    try {
      final p = await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: highAccuracy ? LocationAccuracy.high : LocationAccuracy.medium,
          timeLimit: timeout,
        ),
      );
      return _toFix(p);
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// A reading this good (in metres) is as good as a phone gets outdoors, so there is no need to wait longer.
  static const _goodEnoughM = 15.0;

  @override
  Future<GeoFix?> preciseFix({Duration timeout = const Duration(seconds: 20)}) async {
    GeoFix? best;
    final done = Completer<void>();
    StreamSubscription<Position>? sub;
    try {
      sub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 0),
      ).listen(
        (p) {
          final f = _toFix(p);
          if (best == null || (f.accuracyM ?? double.infinity) < (best!.accuracyM ?? double.infinity)) best = f;
          if ((best!.accuracyM ?? double.infinity) <= _goodEnoughM && !done.isCompleted) done.complete();
        },
        onError: (Object _) {
          if (!done.isCompleted) done.complete();
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
      );
      await Future.any<void>([done.future, Future<void>.delayed(timeout)]);
    } catch (_) {
      // fall through with whatever was read
    } finally {
      await sub?.cancel();
    }
    return best;
  }

  @override
  Future<GeoFix?> lastKnown() async {
    try {
      final p = await Geolocator.getLastKnownPosition();
      return p == null ? null : _toFix(p);
    } catch (_) {
      return null;
    }
  }

  GeoFix _toFix(Position p) => GeoFix(lat: p.latitude, lon: p.longitude, accuracyM: p.accuracy, at: p.timestamp);
}
