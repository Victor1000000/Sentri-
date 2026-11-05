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

/// One answer from the phone's own street finder: a named position.
class StreetHit {
  const StreetHit(this.place, this.lat, this.lon);
  final Place place;
  final double lat, lon;
}

/// Searches street names with the phone's own geocoder - the same street service that names the
/// streets on the position card. The free map search carries one street database and the phone
/// carries another, so a local street the free one never mapped - names like 'Adatan' or 'Aregbe'
/// in Abeokuta - still answers here. Never throws; an empty list means the phone has no answer.
class DeviceStreetSearch {
  const DeviceStreetSearch();

  /// [bias] steers the phone's finder toward the person's own city: it is the area / state from
  /// the position card ('Aregbe, Abeokuta, Ogun State'), so 'Aregbe' means the one near the phone.
  Future<List<StreetHit>> search(String query, {required String bias, int max = 5}) async {
    if (query.trim().isEmpty) return const <StreetHit>[];
    try {
      final found = await locationFromAddress('$query, $bias').timeout(const Duration(seconds: 8));
      final out = <StreetHit>[];
      for (final l in found.take(max)) {
        final p = await _reverse(l.latitude, l.longitude);
        if (p == null) continue;
        out.add(StreetHit(p, l.latitude, l.longitude));
      }
      return out;
    } catch (_) {
      return const <StreetHit>[];
    }
  }

  Future<Place?> _reverse(double lat, double lon) async {
    try {
      final marks = await placemarkFromCoordinates(lat, lon).timeout(const Duration(seconds: 6));
      return placeFromPlacemarks(marks);
    } catch (_) {
      return null;
    }
  }
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
