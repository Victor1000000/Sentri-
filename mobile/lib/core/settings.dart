import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'platform/native_bridge.dart';
import 'storage/key_value_store.dart';

/// One pulse reading the app itself took: when, and the beats per minute.
class HeartTake {
  const HeartTake({required this.atMs, required this.bpm});
  final int atMs;
  final int bpm;
}

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

  /// Minutes between drink-water reminders; 0 means reminders are off.
  int waterMinutes = 0;

  /// The map's base layer: 'standard', 'satellite', 'hybrid' or 'night'.
  /// v40: the default is hybrid - imagery with street names on top, which is
  /// what the person expects from a map app, without touching anything.
  String mapType = 'hybrid';

  /// The pulse readings the app itself took, newest last, kept on this phone only.
  /// The health screen shows the recent ones and whether the rate is settling down
  /// or climbing.
  List<HeartTake> heartTakes = const [];

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
      presses: j['presses'] as int? ?? 4,
    );
    dataSaver = j['dataSaver'] as bool? ?? false;
    lastPhone = j['lastPhone'] as String? ?? '';
    onboarded = j['onboarded'] as bool? ?? false;
    language = j['lang'] as String? ?? 'en';
    theme = j['theme'] as String? ?? 'system';
    waterMinutes = j['water'] as int? ?? 0;
    mapType = j['mapType'] as String? ?? 'hybrid';
    try {
      final takes = jsonDecode((await _store.read('heart.v1')) ?? '[]') as List<dynamic>;
      heartTakes = [
        for (final e in takes)
          if (e is Map<String, dynamic> && e['t'] is num && e['b'] is num) HeartTake(atMs: (e['t'] as num).toInt(), bpm: (e['b'] as num).toInt()),
      ];
    } catch (_) {
      heartTakes = const [];
    }
  }

  /// Records one pulse reading the app itself took. The newest 60 stay on the phone;
  /// older ones fall off the list. Never throws: a history hiccup must not eat a reading.
  Future<void> addHeartTake(DateTime at, int bpm) async {
    final list = <HeartTake>[...heartTakes, HeartTake(atMs: at.millisecondsSinceEpoch, bpm: bpm)];
    if (list.length > 60) list.removeRange(0, list.length - 60);
    heartTakes = List.unmodifiable(list);
    try {
      await _store.write('heart.v1', jsonEncode([for (final h in heartTakes) {'t': h.atMs, 'b': h.bpm}]));
    } catch (_) {}
    notifyListeners();
  }

  Future<void> update({
    TriggerSettings? triggers,
    bool? dataSaver,
    String? lastPhone,
    bool? onboarded,
    String? language,
    String? theme,
    int? waterMinutes,
    String? mapType,
  }) async {
    this.triggers = triggers ?? this.triggers;
    this.dataSaver = dataSaver ?? this.dataSaver;
    this.lastPhone = lastPhone ?? this.lastPhone;
    this.onboarded = onboarded ?? this.onboarded;
    this.language = language ?? this.language;
    this.theme = theme ?? this.theme;
    this.waterMinutes = waterMinutes ?? this.waterMinutes;
    this.mapType = mapType ?? this.mapType;
    await _store.write(
      _k,
      jsonEncode({
        'shake': this.triggers.shake,
        'volume': this.triggers.volume,
        'power': this.triggers.power,
        'floating': this.triggers.floating,
        'sens': this.triggers.shakeSensitivity,
        'presses': this.triggers.clampedPresses,
        'dataSaver': this.dataSaver,
        'lastPhone': this.lastPhone,
        'onboarded': this.onboarded,
        'lang': this.language,
        'theme': this.theme,
        'water': this.waterMinutes,
        'mapType': this.mapType,
      }),
    );
    notifyListeners();
  }
}
