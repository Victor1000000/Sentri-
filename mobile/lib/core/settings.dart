import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'platform/native_bridge.dart';
import 'storage/key_value_store.dart';

/// User choices that persist between launches.
class AppSettings extends ChangeNotifier {
  AppSettings(this._store);
  final KeyValueStore _store;
  static const _k = 'settings.v1';

  TriggerSettings triggers = const TriggerSettings();
  bool dataSaver = false;

  /// Their phone number from the last time they set up or signed in. When the server forgets a
  /// session and the person has to sign in again, the phone step starts with this number filled in.
  String lastPhone = '';

  bool onboarded = false;
  String language = 'en';

  /// 'system', 'light' or 'dark'.
  String theme = 'system';

  Future<void> load() async {
    final raw = await _store.read(_k);
    if (raw == null) return;
    final j = jsonDecode(raw) as Map<String, dynamic>;
    triggers = TriggerSettings(
      shake: j['shake'] as bool? ?? true,
      volume: j['volume'] as bool? ?? true,
      power: j['power'] as bool? ?? false,
      floating: j['floating'] as bool? ?? true,
      shakeSensitivity: (j['sens'] as num?)?.toDouble() ?? 1.0,
    );
    dataSaver = j['dataSaver'] as bool? ?? false;
    lastPhone = j['lastPhone'] as String? ?? '';
    onboarded = j['onboarded'] as bool? ?? false;
    language = j['lang'] as String? ?? 'en';
    theme = j['theme'] as String? ?? 'system';
  }

  Future<void> update({
    TriggerSettings? triggers,
    bool? dataSaver,
    String? lastPhone,
    bool? onboarded,
    String? language,
    String? theme,
  }) async {
    this.triggers = triggers ?? this.triggers;
    this.dataSaver = dataSaver ?? this.dataSaver;
    this.lastPhone = lastPhone ?? this.lastPhone;
    this.onboarded = onboarded ?? this.onboarded;
    this.language = language ?? this.language;
    this.theme = theme ?? this.theme;
    await _store.write(
      _k,
      jsonEncode({
        'shake': this.triggers.shake,
        'volume': this.triggers.volume,
        'power': this.triggers.power,
        'floating': this.triggers.floating,
        'sens': this.triggers.shakeSensitivity,
        'dataSaver': this.dataSaver,
        'lastPhone': this.lastPhone,
        'onboarded': this.onboarded,
        'lang': this.language,
        'theme': this.theme,
      }),
    );
    notifyListeners();
  }
}
