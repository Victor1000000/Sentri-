// Phone-number helpers. v43: also the country search for the sign-up picker -
// the picker's list and filter live here so they can be unit-tested.
import 'emergency.dart';

/// Normalises a phone number to E.164 (same rules as the backend). Nigerian local format
/// (0803 123 4567) becomes +234803... Returns null if it is not plausibly a phone number.
String? normalizePhone(String input, {String countryCode = '234'}) {
  final s = input.replaceAll(RegExp(r'[\s\-().]'), '');
  String e164;
  if (RegExp(r'^\+\d+$').hasMatch(s)) {
    e164 = s;
  } else if (RegExp(r'^00\d+$').hasMatch(s)) {
    e164 = '+${s.substring(2)}';
  } else if (RegExp(r'^0\d+$').hasMatch(s)) {
    e164 = '+$countryCode${s.substring(1)}';
  } else if (RegExp('^$countryCode\\d+\$').hasMatch(s)) {
    e164 = '+$s';
  } else {
    return null;
  }
  if (!RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(e164)) return null;
  if (e164.startsWith('+234') && e164.length != 14) return null;
  return e164;
}

enum ContactsProblem { tooFewOrMany, invalid, duplicate, ownNumber }

/// Validates the contact list: 2-10 distinct valid numbers, none the user's own.
/// Two are enough at sign-up; the remaining slots are filled in the app later.
/// Returns the normalised numbers, or the problem found.
({List<String>? phones, ContactsProblem? problem}) validateContactNumbers(
  List<String> raw, {
  required String ownPhone,
  String countryCode = '234',
}) {
  final entered = raw.where((r) => r.trim().isNotEmpty).toList();
  if (entered.length < 2 || entered.length > 10) return (phones: null, problem: ContactsProblem.tooFewOrMany);
  final out = <String>[];
  for (final r in entered) {
    final p = normalizePhone(r, countryCode: countryCode);
    if (p == null) return (phones: null, problem: ContactsProblem.invalid);
    if (p == ownPhone) return (phones: null, problem: ContactsProblem.ownNumber);
    if (out.contains(p)) return (phones: null, problem: ContactsProblem.duplicate);
    out.add(p);
  }
  return (phones: out, problem: null);
}

/// The countries for the sign-up picker, filtered by what the person typed
/// (v43). An empty query returns every country, alphabetically; a query matches
/// a country's English name (prefix matches first, then anywhere), its dial
/// code (with or without the plus), or its ISO code. Pure and list-only, so
/// the picker's filtering can be unit-tested without a widget tree.
List<SentriCountry> searchCountries(String query) {
  final all = [...sentriCountries]..sort((a, b) => a.name.compareTo(b.name));
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return all;
  final dq = q.startsWith('+') ? q.substring(1) : q;
  final prefix = <SentriCountry>[];
  final rest = <SentriCountry>[];
  for (final c in all) {
    final name = c.name.toLowerCase();
    if (name.startsWith(q)) {
      prefix.add(c);
    } else if (name.contains(q) || (dq.isNotEmpty && c.dial == dq) || c.iso == q) {
      rest.add(c);
    }
  }
  return [...prefix, ...rest];
}
