import 'dart:convert';

import '../../core/storage/key_value_store.dart';

/// The name and guardian character a person picked for one of their emergency
/// contacts. Saved on this phone only - the character is a personal decoration for
/// this screen, not something the server needs to know about.
class Person {
  const Person({required this.phone, this.name = '', this.badge = ''});
  final String phone;

  /// The friendly display name, or the empty string when they keep it simple.
  final String name;

  /// Id of the chosen GuardianBadge, e.g. 'commander_f'. Empty = pick one later.
  final String badge;

  Map<String, String> toJson() => {'p': phone, 'n': name, 'b': badge};
  factory Person.fromJson(Map<String, dynamic> j) => Person(
        phone: (j['p'] ?? '') as String,
        name: (j['n'] ?? '') as String,
        badge: (j['b'] ?? '') as String,
      );
}

/// Phone-number keyed store for [Person], kept in the same secure storage as the
/// rest of the app's private data.
class ContactPeople {
  ContactPeople(this._store);
  final KeyValueStore _store;
  static const _k = 'people.v1';

  Map<String, Person> _people = const {};

  Future<Map<String, Person>> load() async {
    try {
      final raw = await _store.read(_k);
      if (raw == null) return _people = const {};
      final list = (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>();
      final m = <String, Person>{};
      for (final j in list) {
        final p = Person.fromJson(j);
        if (p.phone.isNotEmpty) m[p.phone] = p;
      }
      return _people = m;
    } catch (_) {
      return _people = const {};
    }
  }

  /// Saves the whole record for one phone (name and/or badge).
  Future<void> put(Person p) async {
    if (p.phone.isEmpty) return;
    final m = Map<String, Person>.of(_people);
    m[p.phone] = p;
    _people = m;
    await _persist();
  }

  Person? forPhone(String phone) => _people[phone];

  Future<void> _persist() =>
      _store.write(_k, jsonEncode([for (final p in _people.values) p.toJson()]));
}
