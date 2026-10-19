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

/// Validates the onboarding contact list: 3-5 distinct valid numbers, none the user's own.
/// Returns the normalised numbers, or the problem found.
({List<String>? phones, ContactsProblem? problem}) validateContactNumbers(
  List<String> raw, {
  required String ownPhone,
  String countryCode = '234',
}) {
  final entered = raw.where((r) => r.trim().isNotEmpty).toList();
  if (entered.length < 3 || entered.length > 5) return (phones: null, problem: ContactsProblem.tooFewOrMany);
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
