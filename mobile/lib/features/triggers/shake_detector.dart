import 'dart:math';

/// Shake detection for iOS, where the app can only listen while it is open. (Android does this in
/// the native foreground service so it works with the screen off.)
///
/// Counts hard accelerations (total force above [thresholdG]) that are at least [minGap] apart.
/// [requiredShakes] of them within [window] is a trigger. A cooldown prevents double triggers.
class ShakeDetector {
  ShakeDetector({
    this.thresholdG = 2.7,
    this.requiredShakes = 3,
    this.window = const Duration(milliseconds: 1500),
    this.minGap = const Duration(milliseconds: 150),
    this.cooldown = const Duration(seconds: 5),
  });

  final double thresholdG;
  final int requiredShakes;
  final Duration window;
  final Duration minGap;
  final Duration cooldown;

  final List<DateTime> _hits = [];
  DateTime? _lastCooldownStart;

  static const _g = 9.80665;

  /// Feed accelerometer samples in m/s^2 (including gravity). Returns true when a shake gesture completes.
  bool addSample(double x, double y, double z, DateTime now) {
    final g = sqrt(x * x + y * y + z * z) / _g;
    if (g < thresholdG) return false;
    if (_lastCooldownStart != null && now.difference(_lastCooldownStart!) < cooldown) return false;
    if (_hits.isNotEmpty && now.difference(_hits.last) < minGap) return false;

    _hits.add(now);
    _hits.removeWhere((t) => now.difference(t) > window);
    if (_hits.length >= requiredShakes) {
      _hits.clear();
      _lastCooldownStart = now;
      return true;
    }
    return false;
  }
}
