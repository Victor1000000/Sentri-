import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// One business or landmark around the person, straight from OpenStreetMap.
class NearbyPlace {
  const NearbyPlace({required this.name, required this.kind, required this.lat, required this.lon});
  final String name;
  final String kind; // grocery, hotel, gym, hospital...
  final double lat;
  final double lon;
}

/// Live "what is around me" from the free OpenStreetMap Overpass service: hotels, malls,
/// gyms, markets, small shops, hospitals, fuel stations, banks. No key, no cost.
class NearbyPlaces {
  /// [parseOverpass] is pure so it can be tested without a network.
  static Future<List<NearbyPlace>> fetch(LatLng at, {double radiusM = 700, http.Client? client}) async {
    final q = '[out:json][timeout:25];('
        'node(around:$radiusM,${at.latitude},${at.longitude})["amenity"];'
        'node(around:$radiusM,${at.latitude},${at.longitude})["shop"];'
        'node(around:$radiusM,${at.latitude},${at.longitude})["tourism"];'
        'node(around:$radiusM,${at.latitude},${at.longitude})["leisure"];'
        'way(around:$radiusM,${at.latitude},${at.longitude})["amenity"];'
        'way(around:$radiusM,${at.latitude},${at.longitude})["shop"];'
        'way(around:$radiusM,${at.latitude},${at.longitude})["tourism"];'
        'way(around:$radiusM,${at.latitude},${at.longitude})["leisure"];'
        ');out center 40;';
    final uri = Uri.parse('https://overpass-api.de/api/interpreter');
    final res = await (client ?? http.Client()).post(uri, body: {'data': q}, headers: const {'User-Agent': 'Sentri/0.1'});
    if (res.statusCode != 200) return const <NearbyPlace>[];
    return parseOverpass(res.body);
  }

  /// Names a place in everyday words from its OSM tags.
  static String kindLabel(Map<String, String> tags) {
    String? pick(String key, {bool shorten = true}) {
      final v = tags[key];
      if (v == null || v.isEmpty) return null;
      if (!shorten) return v;
      return switch (v) {
        'fitness_centre' || 'sports_centre' => 'gym',
        'marketplace' => 'market',
        'supermarket' || 'convenience' || 'kiosk' || 'greengrocer' || 'bakery' || 'butcher' || 'clothes' || 'mobile_phone' || 'electronics' => 'shop',
        'fast_food' || 'cafe' || 'restaurant' || 'bar' => v == 'fast_food' ? 'food' : v,
        'guest_house' || 'hostel' => 'hotel',
        'fuel' => 'petrol',
        'clinic' || 'doctors' || 'dentist' => 'hospital',
        'public_service' => 'office',
        _ => v,
      };
    }

    return pick('shop') ?? pick('amenity') ?? pick('tourism') ?? pick('leisure') ?? 'place';
  }

  /// Turns an Overpass JSON answer into named places, junk filtered out.
  static List<NearbyPlace> parseOverpass(String body) {
    List<NearbyPlace>? out;
    try {
      final j = jsonDecode(body) as Map<String, dynamic>;
      final elements = (j['elements'] ?? const <dynamic>[]) as List<dynamic>;
      out = <NearbyPlace>[];
      for (final rawEl in elements) {
        final el = rawEl as Map<String, dynamic>;
        final tags = (el['tags'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
        final name = tags['name'];
        if (name == null || '$name'.trim().isEmpty) continue;
        final strTags = tags.map<String, String>((k, v) => MapEntry(k, '$v'));
        final amenity = strTags['amenity'];
        // Street furniture is not a nearby place a person wants to know about.
        const junk = {'parking', 'parking_entrance', 'parking_space', 'bench', 'waste_basket', 'toilets', 'shelter', 'vending_machine', 'bicycle_parking', 'phone', 'atm', 'public_bookcase', 'recycling', 'grave_yard'};
        if (amenity != null && junk.contains(amenity)) continue;
        double lat;
        double lon;
        if (el['type'] == 'node') {
          lat = (el['lat'] as num).toDouble();
          lon = (el['lon'] as num).toDouble();
        } else {
          final c = el['center'] as Map<String, dynamic>?;
          if (c == null) continue;
          lat = (c['lat'] as num).toDouble();
          lon = (c['lon'] as num).toDouble();
        }
        out!.add(NearbyPlace(name: '$name'.trim(), kind: kindLabel(strTags), lat: lat, lon: lon));
      }
    } catch (_) {
      return const <NearbyPlace>[];
    }
    // Duplicates: the same shop can be node and way. Keep one per name per ~10 m.
    final kept = <NearbyPlace>[];
    final d = const Distance();
    for (final p in out!) {
      final same = kept.any((k) => k.name.toLowerCase() == p.name.toLowerCase() && d(LatLng(k.lat, k.lon), LatLng(p.lat, p.lon)) < 12);
      if (!same) kept.add(p);
    }
    return kept;
  }
}
