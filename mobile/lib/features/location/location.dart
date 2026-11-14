import 'dart:async';
import 'dart:math' as math;

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

/// True when a fix is a real GPS-grade position, not a rough tower/Wi-Fi guess.
/// Movement tracking must only sum distances between fixes this good, otherwise
/// drifting readings silently add hundreds of phantom metres.
bool usableForDistance(GeoFix f, {double limitM = 30}) => (f.accuracyM ?? double.infinity) <= limitM;

// ---- travel mode (v41) ----

/// How the person is travelling, read off consecutive position fixes. The map
/// chip, the share screen and the contacts' alert detail all say it in words:
/// "moving on foot", "on a train", "in flight" - so the people watching can
/// picture the journey without watching every fix.
enum TravelMode { still, walk, run, ride, drive, train, flight }

/// Pure classifier from a speed in metres per second to a travel mode. The
/// bands are honest about what a phone can tell apart: walking and running
/// separate around 5-6 m/s, a bike sits under ~12, cars and city traffic
/// under ~35 (126 km/h), fast rail above that, and only true airspeed
/// (342 km/h and up) reads as flight. Anything above is not walked!
TravelMode classifySpeed(double mps) {
  if (mps <= 0.5) return TravelMode.still;
  if (mps <= 2.5) return TravelMode.walk;
  if (mps <= 5.5) return TravelMode.run;
  if (mps <= 12) return TravelMode.ride;
  if (mps <= 35) return TravelMode.drive;
  if (mps <= 95) return TravelMode.train;
  return TravelMode.flight;
}

/// Metres between two coordinates (haversine). Pure, so tests can classify
/// speeds with no location plumbing at all.
double metresBetween(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  double rad(double d) => d * 3.141592653589793 / 180.0;
  final dLat = rad(lat2 - lat1);
  final dLon = rad(lon2 - lon1);
  final s1 = math.sin(dLat / 2);
  final s2 = math.sin(dLon / 2);
  final a = s1 * s1 + math.cos(rad(lat1)) * math.cos(rad(lat2)) * s2 * s2;
  return 2 * r * math.asin(math.sqrt(a.clamp(0.0, 1.0)));
}

/// Speed between two fixes in metres per second, or null when it cannot be
/// trusted: either fix is too rough for distance work, or there is no honest
/// time gap between them. A looser accuracy bar than distance tracking uses -
/// a 40 m fix over a 15-second hop still tells a car from a walker.
double? speedBetween(GeoFix a, GeoFix b) {
  if (!usableForDistance(a, limitM: 50) || !usableForDistance(b, limitM: 50)) return null;
  final dt = b.at.difference(a.at).inMilliseconds / 1000.0;
  if (dt < 1) return null;
  return metresBetween(a.lat, a.lon, b.lat, b.lon) / dt;
}

/// Parses the mode name sent between phones ('walk', 'drive', ...). Unknown or
/// absent stays null - the interface then simply shows no travel line.
TravelMode? travelModeFromName(String? name) {
  for (final m in TravelMode.values) {
    if (m.name == name) return m;
  }
  return null;
}

/// Hysteresis around [classifySpeed]: one noisy fix must not flip the chip
/// from "on foot" to "in flight". A mode only changes once the last three
/// speed readings agree on the same band; until then the previous mode stands.
class TravelWatcher {
  TravelMode _mode = TravelMode.still;
  final _recent = <TravelMode>[];
  static const _agree = 3;

  TravelMode get mode => _mode;

  void reset() {
    _mode = TravelMode.still;
    _recent.clear();
  }

  /// Feed one speed reading (metres per second between two fixes).
  void feed(double mps) {
    final m = classifySpeed(mps);
    if (_recent.length >= _agree) _recent.removeAt(0);
    _recent.add(m);
    if (_recent.length == _agree && _recent.every((x) => x == m) && m != _mode) {
      _mode = m;
    }
  }
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
  Future<GeoFix?> preciseFix({Duration timeout = const Duration(seconds: 25)}) => fix(highAccuracy: true, timeout: timeout);

  /// A continuous stream of the phone's own positions while the person moves — the device
  /// reports every time it has travelled [distanceFilterM] further, fresh each time. Live
  /// workout tracking uses this: distance and the route line grow point by point. Sources
  /// that cannot stream raise [UnsupportedError]; the workout screen then falls back to
  /// asking for single fixes on a timer.
  Stream<GeoFix> positions({double distanceFilterM = 5}) => throw UnsupportedError('no position stream');
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

  /// A reading this good (in metres) is as good as a phone gets outdoors, so there is no
  /// need to wait longer. 8 m was measured too strict on real phones: the pinpoint kept
  /// waiting for a perfect satellite pass the phone never gives. But 15 m was measured too
  /// LOOSE on inexpensive phones: their first satellite pass can sit far off, actually
  /// feeling like "about 300 m wrong" to the person. 10 m keeps the honest fast-fix
  /// behaviour while refusing the first rough pass when the GPS can do better within the
  /// caller's timeout.
  static const _goodEnoughM = 10.0;

  /// A fix worse than this is a tower/Wi-Fi guess, not a position. preciseFix holds it
  /// back unless the timeout runs out with nothing better - a rough area beats nothing.
  static const _uselessM = 120.0;

  @override
  Future<GeoFix?> preciseFix({Duration timeout = const Duration(seconds: 25)}) async {
    GeoFix? best;
    final done = Completer<void>();
    StreamSubscription<Position>? sub;
    try {
      sub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.bestForNavigation, distanceFilter: 0),
      ).listen(
        (p) {
          final f = _toFix(p);
          final acc = f.accuracyM ?? double.infinity;
          if (best == null || acc < (best!.accuracyM ?? double.infinity)) best = f;
          if (acc <= _goodEnoughM && !done.isCompleted) done.complete();
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

  @override
  Stream<GeoFix> positions({double distanceFilterM = 5}) {
    try {
      return Geolocator.getPositionStream(
        locationSettings: LocationSettings(accuracy: LocationAccuracy.bestForNavigation, distanceFilter: distanceFilterM.round()),
      ).map(_toFix);
    } catch (_) {
      return const Stream.empty();
    }
  }

  GeoFix _toFix(Position p) => GeoFix(lat: p.latitude, lon: p.longitude, accuracyM: p.accuracy, at: p.timestamp);
}
