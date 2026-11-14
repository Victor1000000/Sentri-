import 'package:flutter/services.dart';

/// How an emergency was triggered. Matches the server's `trigger` values.
enum TriggerType { floating, volume, shake, power, widget }

class TriggerSettings {
  const TriggerSettings({
    this.shake = true,
    this.volume = true,
    this.power = false,
    this.floating = true,
    this.shakeSensitivity = 1.0,
    this.presses = 4,
  });
  final bool shake;
  final bool volume;

  /// Screen on/off heuristic. Best effort; off by default because it can misfire.
  final bool power;
  final bool floating;

  /// 0.5 (harder to trigger) .. 1.5 (easier).
  final double shakeSensitivity;

  /// v44: how many power-button presses the alert waits for. The person picks
  /// their own number (3..6) so they stay conscious of when the alert goes off;
  /// anything outside the range is clamped on the way through.
  final int presses;

  int get clampedPresses {
    final p = presses;
    if (p < 3) return 3;
    if (p > 6) return 6;
    return p;
  }

  TriggerSettings copyWith({bool? shake, bool? volume, bool? power, bool? floating, double? shakeSensitivity, int? presses}) =>
      TriggerSettings(
        shake: shake ?? this.shake,
        volume: volume ?? this.volume,
        power: power ?? this.power,
        floating: floating ?? this.floating,
        shakeSensitivity: shakeSensitivity ?? this.shakeSensitivity,
        presses: presses ?? this.presses,
      );

  Map<String, Object> toMap() => {
        'shake': shake,
        'volume': volume,
        'power': power,
        'floating': floating,
        'shakeSensitivity': shakeSensitivity,
        'presses': clampedPresses,
      };
}

class NativePermissions {
  const NativePermissions({
    this.overlay = false,
    this.accessibility = false,
    this.batteryUnrestricted = false,
    this.backgroundLocation = false,
  });
  final bool overlay;
  final bool accessibility;
  final bool batteryUnrestricted;

  /// "Allow all the time": needed to send the position while the phone is locked.
  final bool backgroundLocation;
}

/// The seam between Dart and the platform code (Kotlin on Android, Swift on iOS).
/// Tests use a fake; the real one is [MethodChannelBridge].
abstract class NativeBridge {
  /// Called whenever the OS-level trigger fires while the app is running.
  void onTrigger(void Function(TriggerType type) handler);

  /// A trigger that launched or woke the app (cold start from a shake, tile tap, etc.).
  Future<TriggerType?> takePendingTrigger();

  /// Starts (or reconfigures) the always-on protection service. No-op on iOS.
  Future<void> startProtection(TriggerSettings settings);
  Future<void> stopProtection();

  Future<NativePermissions> permissions();

  /// 'overlay' | 'accessibility' | 'battery' | 'app'
  Future<void> openSettings(String which);
}

class MethodChannelBridge implements NativeBridge {
  MethodChannelBridge() {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'onTrigger') {
        final t = _parse(call.arguments as String?);
        if (t != null) _handler?.call(t);
      }
      return null;
    });
  }

  static const _ch = MethodChannel('ng.sentri/native');
  void Function(TriggerType)? _handler;

  static TriggerType? _parse(String? s) {
    for (final t in TriggerType.values) {
      if (t.name == s) return t;
    }
    return null;
  }

  @override
  void onTrigger(void Function(TriggerType type) handler) => _handler = handler;

  @override
  Future<TriggerType?> takePendingTrigger() async => _parse(await _ch.invokeMethod<String>('takePendingTrigger'));

  @override
  Future<void> startProtection(TriggerSettings s) => _ch.invokeMethod<void>('startProtection', s.toMap());

  @override
  Future<void> stopProtection() => _ch.invokeMethod<void>('stopProtection');

  @override
  Future<NativePermissions> permissions() async {
    final m = await _ch.invokeMapMethod<String, bool>('permissions') ?? const {};
    return NativePermissions(
      overlay: m['overlay'] ?? false,
      accessibility: m['accessibility'] ?? false,
      batteryUnrestricted: m['battery'] ?? false,
      backgroundLocation: m['backgroundLocation'] ?? false,
    );
  }

  @override
  Future<void> openSettings(String which) => _ch.invokeMethod<void>('openSettings', which);
}
