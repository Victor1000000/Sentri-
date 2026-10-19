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
