import 'package:geocoding/geocoding.dart';

import '../../core/net/api.dart';

/// Turns a position into a named place. A fake implements this in tests.
abstract class PlaceLookup {
  Future<Place?> lookup(double lat, double lon);
}

/// Street, area, LGA and state from the phone's own place lookup. On Android this is the same service Google Maps
/// uses, so the names match what people see there, and it works without our server. Never throws; null when it has no answer.
class DevicePlaceLookup implements PlaceLookup {
  const DevicePlaceLookup();

  @override
  Future<Place?> lookup(double lat, double lon) async {
    try {
      final marks = await placemarkFromCoordinates(lat, lon).timeout(const Duration(seconds: 6));
      return placeFromPlacemarks(marks);
    } catch (_) {
      return null;
    }
  }
}

String? _clean(String? s) {
  final t = s?.trim();
  return (t == null || t.isEmpty) ? null : t;
}

/// "FHGM+X7" style codes are positions, not names.
bool _isPlusCode(String s) => RegExp(r'^[23456789CFGHJMPQRVWX]{4,8}\+[23456789CFGHJMPQRVWX]{0,3}').hasMatch(s.toUpperCase());

String? _stripSuffix(String? s, RegExp suffix) {
  final c = _clean(s);
  return c == null ? null : _clean(c.replaceAll(suffix, ''));
}

/// Picks the best name for each part from what the phone returned. Pure, so it can be tested without a phone.
Place? placeFromPlacemarks(List<Placemark> marks) {
  String? first(String? Function(Placemark m) pick) {
    for (final m in marks) {
      final v = _clean(pick(m));
      if (v != null) return v;
    }
    return null;
  }

  var street = first((m) => m.thoroughfare) ?? first((m) => m.street);
  if (street != null && _isPlusCode(street)) street = null;
  final number = first((m) => m.subThoroughfare);
  if (street != null && number != null && RegExp(r'^\d+[A-Za-z]?$').hasMatch(number) && !street.startsWith(number)) {
    street = '$number $street';
  }

  final area = first((m) => m.subLocality) ?? first((m) => m.locality);
  final lga = _stripSuffix(first((m) => m.subAdministrativeArea), RegExp(r'\s+(Local Government Area|LGA)$', caseSensitive: false));
  final state = _stripSuffix(first((m) => m.administrativeArea), RegExp(r'\s+State$', caseSensitive: false));

  // A named building or business, when the phone knows one. Not a house number, a plus code, or a repeat of another part.
  String? landmark = first((m) => m.name);
  if (landmark != null) {
    final l = landmark.toLowerCase();
    final repeats = [street, area, lga, state].whereType<String>().any((p) {
      final q = p.toLowerCase();
      return q == l || q.endsWith(l);
    });
    if (!RegExp(r'[A-Za-z]').hasMatch(landmark) || _isPlusCode(landmark) || repeats || landmark.length < 3) landmark = null;
  }

  final parts = [street, area, state].whereType<String>().toList();
  if (parts.isEmpty) return null;
  return Place(street: street, area: area, lga: lga, state: state, landmark: landmark, label: parts.join(', '));
}
