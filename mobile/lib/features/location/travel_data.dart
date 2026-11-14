// Pure helpers behind the Travel tab's live-data cards (v44).
//
// The cards fetch free public feeds - OpenSky for aircraft overhead, the USGS
// feed for recent earthquakes, Open-Meteo for weather right now, and
// OpenStreetMap's Overpass API for registered surveillance cameras nearby.
// These functions turn each raw answer body into small value objects; the
// screen does the fetching. Keeping the parsing here, with no I/O in it, means
// the tests can run it against recorded bodies and the screen stays thin.
//
// Honesty rule the cards follow: when a feed fails or says nothing, the card
// says so - it never invents data to look alive.

import 'dart:convert';
import 'dart:math' as math;

/// Great-circle distance in metres between two WGS84 points.
double haversineM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  final dLat = _rad(lat2 - lat1);
  final dLon = _rad(lon2 - lon1);
  final sLat = math.sin(dLat / 2);
  final sLon = math.sin(dLon / 2);
  final a = sLat * sLat + math.cos(_rad(lat1)) * math.cos(_rad(lat2)) * sLon * sLon;
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return r * c;
}

double _rad(double deg) => deg * 3.1415926535897932 / 180.0;

double? _num(Object? v) => v is num ? v.toDouble() : null;

String? _str(Object? v) {
  final s = v is String ? v.trim() : '';
  return s.isEmpty ? null : s;
}

/// One aircraft the OpenSky feed reports overhead.
class OverheadFlight {
  const OverheadFlight({
    required this.callsign,
    required this.country,
    required this.distanceM,
    this.altitudeM,
    this.speedKmh,
  });
  final String callsign;
  final String country;
  final double distanceM;
  final int? altitudeM; // metres
  final double? speedKmh;
}

/// Parses an OpenSky `states/all` answer (bounding-box fetch) into flights,
/// nearest first, airborne only. Rows are positional; anything malformed or
/// on the ground is skipped, and a broken body yields an empty list.
List<OverheadFlight> parseOverheadFlights(String body, double lat, double lon, {int limit = 6}) {
  try {
    final j = jsonDecode(body);
    final states = j is Map<String, dynamic> ? j['states'] : null;
    if (states is! List) return const [];
    final out = <OverheadFlight>[];
    for (final row in states) {
      if (row is! List || row.length < 11) continue;
      final rlat = _num(row[6]);
      final rlon = _num(row[5]);
      if (rlat == null || rlon == null) continue;
      if (row[8] == true) continue; // on the ground: not overhead traffic
      final vel = _num(row[9]);
      final alt = _num(row[7]);
      final cs = _str(row[1]) ?? _str(row[0]) ?? '';
      if (cs.isEmpty) continue;
      out.add(OverheadFlight(
        callsign: cs,
        country: _str(row[2]) ?? '',
        distanceM: haversineM(lat, lon, rlat, rlon),
        altitudeM: alt == null ? null : alt.round(),
        speedKmh: vel == null ? null : vel * 3.6,
      ));
    }
    out.sort((a, b) => a.distanceM.compareTo(b.distanceM));
    return out.take(limit).toList();
  } catch (_) {
    return const [];
  }
}

/// One recent earthquake from the USGS feed.
class NearbyQuake {
  const NearbyQuake({
    required this.place,
    required this.magnitude,
    required this.depthKm,
    required this.distanceM,
  });
  final String place;
  final double magnitude;
  final double depthKm;
  final double distanceM;
}

/// Parses a USGS GeoJSON answer (radius query) into quakes within [maxKm] of
/// the person, nearest first. Features without a usable magnitude or position
/// are skipped; a broken body yields an empty list.
List<NearbyQuake> parseNearbyQuakes(String body, double lat, double lon, {double maxKm = 500}) {
  try {
    final j = jsonDecode(body);
    final features = j is Map<String, dynamic> ? j['features'] : null;
    if (features is! List) return const [];
    final out = <NearbyQuake>[];
    for (final f in features) {
      if (f is! Map<String, dynamic>) continue;
      final props = f['properties'];
      final geom = f['geometry'];
      if (props is! Map<String, dynamic> || geom is! Map<String, dynamic>) continue;
      final coords = geom['coordinates'];
      if (coords is! List || coords.length < 3) continue;
      final qlon = _num(coords[0]);
      final qlat = _num(coords[1]);
      final depth = _num(coords[2]);
      final mag = _num(props['mag']);
      final place = _str(props['place']);
      if (qlat == null || qlon == null || mag == null || place == null) continue;
      final d = haversineM(lat, lon, qlat, qlon);
      if (d > maxKm * 1000) continue;
      out.add(NearbyQuake(
        place: place,
        magnitude: mag,
        depthKm: depth ?? 0,
        distanceM: d,
      ));
    }
    out.sort((a, b) => a.distanceM.compareTo(b.distanceM));
    return out;
  } catch (_) {
    return const [];
  }
}

/// Weather right now, from Open-Meteo's no-key `current` block.
class WeatherNow {
  const WeatherNow({required this.tempC, required this.windKmh, required this.precipMm, required this.code});
  final double tempC;
  final double windKmh;
  final double precipMm;
  final int code;
}

/// Parses an Open-Meteo answer into the current conditions, or null when the
/// body is broken or the `current` block is missing.
WeatherNow? parseWeather(String body) {
  try {
    final j = jsonDecode(body);
    final cur = j is Map<String, dynamic> ? j['current'] : null;
    if (cur is! Map<String, dynamic>) return null;
    final temp = _num(cur['temperature_2m']);
    if (temp == null) return null;
    return WeatherNow(
      tempC: temp,
      windKmh: _num(cur['wind_speed_10m']) ?? 0,
      precipMm: _num(cur['precipitation']) ?? 0,
      code: (cur['weather_code'] as num?)?.toInt() ?? 0,
    );
  } catch (_) {
    return null;
  }
}

/// One registered surveillance camera near the person, from OpenStreetMap.
class SafetyCamera {
  const SafetyCamera({required this.name, required this.kind, required this.distanceM});
  final String name; // may be empty: many cameras have no name tag
  final String kind; // e.g. 'fixed', 'ALPR' - whatever tags said
  final double distanceM;
}

/// Parses an Overpass answer (nodes around the person tagged
/// `man_made=surveillance`) into cameras, nearest first. A broken body yields
/// an empty list.
List<SafetyCamera> parseCameras(String body, double lat, double lon) {
  try {
    final j = jsonDecode(body);
    final elements = j is Map<String, dynamic> ? j['elements'] : null;
    if (elements is! List) return const [];
    final out = <SafetyCamera>[];
    for (final e in elements) {
      if (e is! Map<String, dynamic>) continue;
      final clat = _num(e['lat']);
      final clon = _num(e['lon']);
      if (clat == null || clon == null) continue;
      final tags = e['tags'];
      final kind = tags is Map<String, dynamic> ? (_str(tags['surveillance:type']) ?? 'fixed') : 'fixed';
      final name = tags is Map<String, dynamic> ? (_str(tags['name']) ?? '') : '';
      out.add(SafetyCamera(
        name: name,
        kind: kind,
        distanceM: haversineM(lat, lon, clat, clon),
      ));
    }
    out.sort((a, b) => a.distanceM.compareTo(b.distanceM));
    return out;
  } catch (_) {
    return const [];
  }
}
