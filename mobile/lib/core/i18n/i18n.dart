import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/foundation.dart';

/// A language the app ships. To add one: drop `assets/i18n/<code>.json` next to the others and add a
/// line here. Missing keys fall back to English, so a new language can ship partially translated.
class AppLanguage {
  const AppLanguage(this.code, this.nativeName);
  final String code;
  final String nativeName;
}

const supportedLanguages = <AppLanguage>[
  AppLanguage('en', 'English'),
  AppLanguage('ha', 'Hausa'),
  AppLanguage('yo', 'Yorùbá'),
  AppLanguage('ig', 'Igbo'),
  AppLanguage('pcm', 'Naijá (Pidgin)'),
];

typedef AssetLoader = Future<String> Function(String path);

/// Minimal translation lookup. Deliberately not tied to Flutter's `Locale`/Material localizations,
/// because Pidgin (`pcm`) is not a locale Flutter's own widgets support.
class I18n extends ChangeNotifier {
  I18n({AssetLoader? loader}) : _load = loader ?? rootBundle.loadString;

  final AssetLoader _load;
  final Map<String, Map<String, String>> _tables = {};
  String _code = 'en';

  String get code => _code;

  Future<void> init(String code) async {
    await _ensure('en');
    await setLanguage(code);
  }

  Future<void> setLanguage(String code) async {
    final known = supportedLanguages.any((l) => l.code == code);
    final use = known ? code : 'en';
    await _ensure(use);
    _code = use;
    notifyListeners();
  }

  Future<void> _ensure(String code) async {
    if (_tables.containsKey(code)) return;
    final raw = await _load('assets/i18n/$code.json');
    final json = jsonDecode(raw) as Map<String, dynamic>;
    _tables[code] = json.map((k, v) => MapEntry(k, v as String));
  }

  /// Looks the key up in the current language, then English, then returns the key itself.
  /// `{name}` style placeholders are filled from [args].
  String t(String key, [Map<String, String> args = const {}]) {
    var s = _tables[_code]?[key] ?? _tables['en']?[key] ?? key;
    args.forEach((k, v) => s = s.replaceAll('{$k}', v));
    return s;
  }
}
