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
  // v40, global: French and Spanish ship as full translations - every key the
  // English table carries is translated, and test_units.dart enforces that.
  AppLanguage('fr', 'Français'),
  AppLanguage('es', 'Español'),
  // v42, world: the countries outside Nigeria speak more than English, so the
  // language sheet now offers the major language of each region too. Each one
  // ships as a full translation of every English key, and the parity test
  // covers them automatically. The translations are machine-assisted.
  AppLanguage('sw', 'Kiswahili'),
  AppLanguage('am', 'አማርኛ'),
  AppLanguage('pt', 'Português'),
  AppLanguage('de', 'Deutsch'),
  AppLanguage('it', 'Italiano'),
  AppLanguage('ar', 'العربية'),
  AppLanguage('tr', 'Türkçe'),
  AppLanguage('id', 'Bahasa Indonesia'),
  AppLanguage('hi', 'हिन्दी'),
  AppLanguage('ja', '日本語'),
  AppLanguage('ko', '한국어'),
  AppLanguage('ru', 'Русский'),
];

AppLanguage _lang(String code) => supportedLanguages.firstWhere((l) => l.code == code);

/// v41, per country: the languages the language sheet offers. A Nigerian number
/// opens the Nigerian set (English, Pidgin, Hausa, Yoruba, Igbo); the French and
/// Spanish speaking countries get their language alongside English; everywhere
/// else English alone. `current` is always included, so nobody can ever be
/// switched into a list that hides the language they are reading.
///
/// v42, world: each region's major language joins the sheet for that region's
/// countries, next to English (or French/Spanish where those are the regional
/// second language). English always stays on every list, so any country whose
/// language is not shipped yet still reads it - nothing here can lock a person
/// out of the app's words.
List<AppLanguage> languagesForCountry(String? iso, {String current = 'en'}) {
  final set = switch (iso?.toLowerCase()) {
    'ng' => ['en', 'pcm', 'ha', 'yo', 'ig'],
    // v42: the wider world, language by language.
    'ke' || 'tz' || 'ug' => ['en', 'sw'],
    'et' => ['en', 'am'],
    'pt' || 'br' || 'ao' || 'mz' => ['en', 'pt'],
    'de' || 'at' => ['en', 'de'],
    'ch' => ['en', 'de', 'fr', 'it'],
    'it' => ['en', 'it'],
    'fr' || 'sn' || 'ci' || 'cm' || 'dz' || 'ma' || 'tn' || 'cd' || 'rw' || 'be' => ['en', 'fr'],
    'es' || 'mx' || 'ar' || 'cl' || 'co' || 'pe' => ['en', 'es'],
    'eg' || 'sa' || 'ae' => ['en', 'ar'],
    'tr' => ['en', 'tr'],
    'id' => ['en', 'id'],
    'in' => ['en', 'hi'],
    'jp' => ['en', 'ja'],
    'kr' => ['en', 'ko'],
    'ru' => ['en', 'ru'],
    _ => ['en'],
  };
  final out = <AppLanguage>[];
  for (final c in set) {
    if (_hasLang(c)) out.add(_lang(c));
  }
  // The language the person is reading stays on the list, always.
  if (current != 'en' && _hasLang(current) && !out.contains(_lang(current))) out.add(_lang(current));
  return out;
}

bool _hasLang(String code) => supportedLanguages.any((l) => l.code == code);

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
