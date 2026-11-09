import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart' show Geolocator, Position, LocationSettings, LocationAccuracy;
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;

import '../../core/config.dart';
import '../../core/i18n/i18n.dart';
import '../../core/net/api.dart';
import '../location/location.dart';
import '../location/place_lookup.dart';
import '../police/nearest_police.dart';
import '../police/police_directory.dart';
import 'nearby_places.dart';
import 'step_voice.dart';

/// One planned route from the router: the line to draw, what it costs, and the step texts.
class _RoutePlan {
  const _RoutePlan({required this.points, required this.dest, required this.destName, required this.km, required this.mins, required this.stepTexts, required this.stepLocs, required this.stepSay});
  final List<LatLng> points;
  final LatLng dest;
  final String destName;
  final double km;
  final int mins;
  final List<String> stepTexts;
  /// Where each instruction happens (the maneuver point), so the voice can speak it on approach.
  final List<LatLng> stepLocs;
  final List<String> stepSay;
  String get kmText => km >= 10 ? km.round().toString() : km.toStringAsFixed(1);
  String get minText => '$mins';
}

/// One answer from the place search: a typed name that resolved to a point on the map.
class _SearchHit {
  const _SearchHit({required this.name, required this.detail, required this.lat, required this.lon, required this.km});
  final String name;
  final String detail;
  final double lat;
  final double lon;
  /// Straight-line distance from the phone, in kilometres. Consulted during the search: the list
  /// is sorted with it and shows it, so a match from another country is obviously a far one.
  final double km;
}

bool _sameWord(String a, String b) => a.trim().toLowerCase() == b.trim().toLowerCase();

/// The map, Google Maps-style: the map is the whole screen and every control is a floating
/// round icon. The person can type where they are going (search picks the exact spot), or
/// long-press the map to drop a point. Nearby named places are written on the map, the way
/// Google Maps and Organic Maps show them.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key, required this.location, required this.api, required this.i18n, this.placeLookup, this.onPlace, this.refresh = const Duration(seconds: 6), this.police});
  final LocationSource location;
  final SentriApi api;
  final I18n i18n;

  /// The police commands, parsed once by the app shell. With no points picked, directions aim
  /// at the closest command's post. Null: the button then stays disabled.
  final Future<PoliceDirectory>? police;

  /// The phone's own place lookup, tried first. The server is the fallback.
  final PlaceLookup? placeLookup;
  final ValueChanged<Place?>? onPlace;
  final Duration refresh;

  @override
  MapScreenState createState() => MapScreenState();
}

/// Public so the tab shell can hold a [GlobalKey] to it: the Health tab sends
/// a tapped hospital or gym here with [routeTo] and the map plans the route.
class MapScreenState extends State<MapScreen> {
  final _map = MapController();
  final _voice = StepVoice();
  GeoFix? _fix;
  Place? _place;
  bool _denied = false;
  Timer? _timer;
  int _lookupSeq = 0;
  LatLng? _lastLookedUp;
  _RoutePlan? _route;
  bool _routeBusy = false;
  String? _routeError;
  /// True when the error on the card is one touching Retry can actually fix (network or GPS).
  bool _routeRetry = false;
  int _routeSeq = 0;

  // -- picked points: directions work between any two spots on the map --
  LatLng? _fromPick;
  String? _fromName;
  LatLng? _toPick;
  String? _toName;
  String? _pickMode; // 'from' | 'to' while waiting for a long-press

  // ---- typed destination search ----

  /// Only place matches this close to the phone count as "nearby" answers; anything farther is
  /// kept only as a last resort and clearly flagged in the list.
  static const double _searchLocalKm = 70.0;

  int _searchSeq = 0;

  /// The phone's own street finder - the database the position card names streets from, used when
  /// the free map indexes have no local answer.
  final _streetSearch = const DeviceStreetSearch();

  /// A short "2.1 km" / "1,204 km" distance for a search hit.
  static String _kmText(double km) => km >= 100 ? '${km.round()} km' : '${km.toStringAsFixed(1)} km';

  /// A box around the phone about 60 km across, for the bounded name service.
  static String _bbox(LatLng near) {
    const span = 0.6;
    return '${(near.longitude - span).toStringAsFixed(4)},${(near.latitude + span).toStringAsFixed(4)},${(near.longitude + span).toStringAsFixed(4)},${(near.latitude - span).toStringAsFixed(4)}';
  }

  // -- the way of travelling: car, foot or bike, chosen like on a real navigator --
  String _mode = 'driving';

  // -- spoken turn-by-turn --
  bool _voiceOn = false;
  int _nextStep = 0;
  StreamSubscription<Position>? _posSub;

  // -- what is around --
  List<NearbyPlace> _near = const <NearbyPlace>[];
  bool _nearBusy = false;
  LatLng? _nearFetchedAt;

  @override
  void initState() {
    super.initState();
    unawaited(_update());
    _timer = Timer.periodic(widget.refresh, (_) => unawaited(_update()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_posSub?.cancel());
    unawaited(_voice.stop());
    _map.dispose();
    super.dispose();
  }

  bool _busy = false;

  /// Shows the phone's last known position at once, then settles on a precise one. One round at a time.
  Future<void> _update() async {
    if (_busy) return;
    _busy = true;
    try {
      if (_fix == null) {
        final quick = await widget.location.lastKnown();
        if (!mounted) return;
        if (quick != null) _apply(quick);
      }
      final f = await widget.location.preciseFix(timeout: const Duration(seconds: 25));
      if (!mounted) return;
      if (f == null) {
        if (_fix == null) setState(() => _denied = true);
        return;
      }
      _apply(f);
    } finally {
      _busy = false;
    }
  }

  void _apply(GeoFix f) {
    setState(() {
      _fix = f;
      _denied = false;
    });
    final here = LatLng(f.lat, f.lon);
    try {
      _map.move(here, _map.camera.zoom < 15 ? 17 : _map.camera.zoom);
    } catch (_) {
      // The map is not built yet; the initial centre covers it.
    }
    // Look the name up again only after moving about 50 m.
    if (_lastLookedUp == null || const Distance()(_lastLookedUp!, here) > 50) {
      _lastLookedUp = here;
      unawaited(_lookupPlace(f.lat, f.lon));
    }
    // Refresh the nearby list only after walking/driving far enough for it to matter.
    if (_nearFetchedAt == null || const Distance()(_nearFetchedAt!, here) > 300) {
      _nearFetchedAt = here;
      unawaited(_fetchNearby(here));
    }
  }

  /// The phone's own lookup first (the same names Google Maps shows), then the server.
  Future<void> _lookupPlace(double lat, double lon) async {
    final seq = ++_lookupSeq;
    Place? p;
    final lookup = widget.placeLookup;
    if (lookup != null) {
      try {
        p = await lookup.lookup(lat, lon);
      } catch (_) {
        p = null;
      }
    }
    if (p == null) {
      try {
        p = await widget.api.reverseGeocode(lat, lon);
      } catch (_) {
        p = null;
      }
    }
    if (!mounted || seq != _lookupSeq) return;
    if (p == null && _place == null) _lastLookedUp = null; // nothing yet: try again on the next round
    setState(() => _place = p ?? _place);
    widget.onPlace?.call(_place);
  }

  /// A short name for a dropped point: the street or area, else plain "point".
  Future<String> _pointName(double lat, double lon) async {
    final t = widget.i18n.t;
    final lookup = widget.placeLookup;
    if (lookup != null) {
      try {
        final p = await lookup.lookup(lat, lon);
        final name = p?.street ?? p?.area;
        if (name != null && name.isNotEmpty) return name;
      } catch (_) {}
    }
    try {
      final p = await widget.api.reverseGeocode(lat, lon);
      final name = p?.street ?? p?.area;
      if (name != null && name.isNotEmpty) return name;
    } catch (_) {}
    return t('map.dropped');
  }

  // ---- nearby places ----

  Future<void> _fetchNearby(LatLng here) async {
    if (_nearBusy) return;
    _nearBusy = true;
    try {
      final list = await NearbyPlaces.fetch(here);
      list.sort((a, b) {
        final d = const Distance();
        return d(here, LatLng(a.lat, a.lon)).compareTo(d(here, LatLng(b.lat, b.lon)));
      });
      if (!mounted) return;
      setState(() => _near = list.take(25).toList());
    } catch (_) {
      // The map stays useful without the list.
    } finally {
      _nearBusy = false;
    }
  }

  void _showNearby() {
    final t = widget.i18n.t;
    final cs = Theme.of(context).colorScheme;
    final here = _fix == null ? null : LatLng(_fix!.lat, _fix!.lon);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: _near.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(22),
                child: Text(t('map.nearby_none'), style: TextStyle(fontSize: 15, height: 1.35, color: cs.onSurface)),
              )
            : ListView.builder(
                shrinkWrap: true,
                itemCount: _near.length,
                itemBuilder: (ctx, i) {
                  final p = _near[i];
                  final m = here == null ? null : const Distance()(here, LatLng(p.lat, p.lon)).round();
                  return ListTile(
                    dense: true,
                    leading: Icon(_nearIcon(p.kind), size: 22, color: const Color(0xFF6A5FF0)),
                    title: Text(p.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    subtitle: Text(m == null ? p.kind : '${p.kind} - ${t('map.nearby_far', {'m': '$m'})}', style: TextStyle(fontSize: 12.5, color: cs.outline)),
                    onTap: () {
                      Navigator.of(ctx).pop();
                      try {
                        _map.move(LatLng(p.lat, p.lon), _map.camera.zoom < 17 ? 18 : _map.camera.zoom);
                      } catch (_) {}
                    },
                  );
                },
              ),
      ),
    );
  }

  IconData _nearIcon(String kind) {
    switch (kind) {
      case 'hotel':
        return Icons.hotel_outlined;
      case 'gym':
        return Icons.fitness_center;
      case 'market' || 'shop' || 'store':
        return Icons.storefront_outlined;
      case 'hospital':
        return Icons.local_hospital_outlined;
      case 'police':
        return Icons.local_police_outlined;
      case 'petrol' || 'fuel':
        return Icons.local_gas_station_outlined;
      case 'bank' || 'atm':
        return Icons.account_balance_outlined;
      case 'restaurant' || 'cafe' || 'bar' || 'food' || 'pub':
        return Icons.restaurant_outlined;
      case 'pharmacy':
        return Icons.medication_outlined;
      case 'school' || 'university':
        return Icons.school_outlined;
      case 'park':
        return Icons.park_outlined;
      case 'cinema':
        return Icons.movie_outlined;
      case 'library':
        return Icons.local_library_outlined;
      default:
        return Icons.place_outlined;
    }
  }

  // ---- typed destination search ----

  /// One Photon (Komoot) question, no key, free. `osmTag` picks what it answers with: 'highway'
  /// is the named-road index (the actual streets), 'place' is towns, villages, suburbs and
  /// neighbourhoods, and null means the ordinary nearby index (shops, schools, addresses).
  Future<void> _searchPhoton(String query, LatLng near, String? osmTag, List<_SearchHit> hits) async {
    try {
      var url = 'https://photon.komoot.io/api?limit=8&lang=en&lat=${near.latitude}&lon=${near.longitude}&q=${Uri.encodeQueryComponent(query)}';
      if (osmTag != null) url += '&osm_tag=${Uri.encodeQueryComponent(osmTag)}';
      final res = await http.get(Uri.parse(url), headers: const {'User-Agent': 'Sentri/0.1'}).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        for (final f in (j['features'] ?? const <dynamic>[]) as List<dynamic>) {
          final props = ((f as Map<String, dynamic>)['properties'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
          final geo = ((f['geometry'] ?? const <String, dynamic>{}) as Map<String, dynamic>);
          final coords = (geo['coordinates'] ?? const <dynamic>[]) as List<dynamic>;
          if (coords.length < 2) continue;
          final name = '${props['name'] ?? ''}'.trim();
          if (name.isEmpty) continue;
          final parts = <String>['${props['district'] ?? ''}', '${props['street'] ?? ''}', '${props['city'] ?? ''}', '${props['county'] ?? ''}', '${props['state'] ?? ''}'];
          final detail = [for (final x in parts) if (x.trim().isNotEmpty && !_sameWord(name, x)) x].join(', ');
          final pt = LatLng((coords[1] as num).toDouble(), (coords[0] as num).toDouble());
          hits.add(_SearchHit(name: name, detail: detail, lat: pt.latitude, lon: pt.longitude, km: const Distance()(near, pt) / 1000.0));
        }
      }
    } catch (_) {}
  }

  /// Nominatim (the OSM name service), free, no key. With a box it only answers inside the box
  /// around the phone; without one it answers anywhere on earth, which is the last resort for a
  /// name that is not mapped near the person at all.
  Future<void> _searchNominatim(String query, String? bbox, List<_SearchHit> hits, LatLng near) async {
    try {
      var url = 'https://nominatim.openstreetmap.org/search?format=jsonv2&limit=${bbox == null ? 6 : 10}&countrycodes=ng&q=${Uri.encodeQueryComponent(query)}';
      if (bbox != null) url += '&viewbox=$bbox&bounded=1';
      final res = await http.get(Uri.parse(url), headers: const {'User-Agent': 'Sentri/0.1'}).timeout(const Duration(seconds: 12));
      if (res.statusCode == 200) {
        for (final raw in (jsonDecode(res.body) ?? const <dynamic>[]) as List<dynamic>) {
          final r = raw as Map<String, dynamic>;
          final display = '${r['display_name'] ?? ''}'.trim();
          if (display.isEmpty) continue;
          final lat = double.tryParse('${r['lat'] ?? ''}');
          final lon = double.tryParse('${r['lon'] ?? ''}');
          if (lat == null || lon == null) continue;
          final seg = display.split(', ');
          final pt = LatLng(lat, lon);
          hits.add(_SearchHit(name: seg.first, detail: seg.skip(1).take(2).join(', '), lat: lat, lon: lon, km: const Distance()(near, pt) / 1000.0));
        }
      }
    } catch (_) {}
  }

  /// Local-first search for a typed name. Street names, area names and POIs around the phone are
  /// asked first (roads, areas, everything else in parallel), then the name service inside a box
  /// around the phone. When none of the free map indexes knows something near the phone, the
  /// phone's own street finder gets the last word - it carries the streets the free maps miss.
  /// Only if not a single thing answers nearby do the worldwide answers appear, sorted by
  /// distance and shown with how far each one is, under an honest note.
  Future<List<_SearchHit>> _searchPlaces(String query, LatLng near) async {
    final hits = <_SearchHit>[];
    // The free map indexes and the phone's own street finder are different street databases;
    // both are asked at once and their answers are merged, because streets the free maps never
    // mapped (Abeokuta's 'Adatan', 'Aregbe', 'Abiola Way') are on the phone's database - the
    // same one the position card names streets from.
    final p = _place;
    final bias = [for (final x in <String?>[p?.area, p?.lga, p?.state, 'Nigeria']) if (x != null && x.trim().isNotEmpty) x].join(', ');
    await Future.wait([
      _searchPhoton(query, near, 'highway', hits),
      _searchPhoton(query, near, 'place', hits),
      _searchPhoton(query, near, null, hits),
      _searchDevice(query, near, bias, hits),
    ]);
    if (hits.isEmpty) await _searchNominatim(query, _bbox(near), hits, near);
    // The same road can come back from more than one index.
    final seen = <String>{};
    hits.retainWhere((h) {
      final key = '${h.name.toLowerCase()}|${h.lat.toStringAsFixed(3)}|${h.lon.toStringAsFixed(3)}';
      if (seen.contains(key)) return false;
      seen.add(key);
      return true;
    });
    final hasLocal = hits.any((h) => h.km <= _searchLocalKm);
    if (hasLocal) hits.retainWhere((h) => h.km <= _searchLocalKm);
    hits.sort((a, b) => a.km.compareTo(b.km));
    return hits.take(hasLocal ? 12 : 6).toList();
  }

  /// Asks the phone's own street finder and folds its answers into the shared hit list. Silent
  /// on phones without the service, so the free indexes still carry the search alone.
  Future<void> _searchDevice(String query, LatLng near, String bias, List<_SearchHit> hits) async {
    final phone = await _streetSearch.search(query, bias: bias);
    final seen = <String>{};
    for (final s in phone) {
      var name = s.place.street ?? s.place.landmark ?? s.place.area;
      if (name == null || name.trim().isEmpty) continue;
      name = name.trim();
      final key = '${name.toLowerCase()}|${s.lat.toStringAsFixed(3)}|${s.lon.toStringAsFixed(3)}';
      if (!seen.add(key)) continue;
      final detail = [for (final x in <String?>[s.place.area, s.place.lga, s.place.state]) if (x != null && x.trim().isNotEmpty && !_sameWord(name, x)) x].join(', ');
      hits.add(_SearchHit(name: name, detail: detail, lat: s.lat, lon: s.lon, km: const Distance()(near, LatLng(s.lat, s.lon)) / 1000.0));
    }
  }

  /// "Where to?" — the person types where they are going, the app picks the exact spot and
  /// routes there from the phone's current position right away.
  Future<void> _searchDestination() async {
    final t = widget.i18n.t;
    final cs = Theme.of(context).colorScheme;
    final near = _fix == null ? const LatLng(9.0820, 7.4730) : LatLng(_fix!.lat, _fix!.lon);
    final controller = TextEditingController();
    Timer? debounce;
    var searched = false;
    var busy = false;
    // True when every answer comes from far away: the name simply is not mapped near the person.
    var farOnly = false;
    final hits = <_SearchHit>[];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        StateSetter refreshSheet = (fn) => {};
        void run(String query) {
          debounce?.cancel();
          final q = query.trim();
          if (q.length < 3) return;
          debounce = Timer(const Duration(milliseconds: 600), () async {
            final seq = ++_searchSeq;
            if (!ctx.mounted) return;
            refreshSheet(() { busy = true; searched = false; hits.clear(); });
            final res = await _searchPlaces(q, near);
            if (!ctx.mounted || seq != _searchSeq) return;
            refreshSheet(() {
              busy = false;
              searched = true;
              farOnly = res.isNotEmpty && res.every((h) => h.km > _searchLocalKm);
              hits.addAll(res);
            });
          });
        }

        return StatefulBuilder(
          builder: (ctx, refresh) {
            refreshSheet = refresh;
            return Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
                    child: TextField(
                      controller: controller,
                      autofocus: true,
                      textInputAction: TextInputAction.search,
                      onChanged: run,
                      onSubmitted: run,
                      decoration: InputDecoration(
                        hintText: t('map.search_hint'),
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: ValueListenableBuilder<TextEditingValue>(
                          valueListenable: controller,
                          builder: (context, v, _) => v.text.isEmpty
                              ? const SizedBox.shrink()
                              : IconButton(
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () {
                                    controller.clear();
                                    refreshSheet(() { searched = false; busy = false; farOnly = false; hits.clear(); });
                                  },
                                  icon: const Icon(Icons.close, size: 20),
                                ),
                        ),
                      ),
                    ),
                  ),
                  if (busy) ...[
                    Padding(
                      padding: const EdgeInsets.all(18),
                      child: Row(children: [
                        const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 12),
                        Text(t('map.searching'), style: TextStyle(fontSize: 14, color: cs.onSurface.withValues(alpha: 0.65))),
                      ]),
                    ),
                  ] else if (searched && controller.text.trim().length >= 3 && hits.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(18),
                      child: Text(t('map.search_no_results'), style: TextStyle(fontSize: 14, height: 1.35, color: cs.onSurface.withValues(alpha: 0.65))),
                    )
                  else if (!searched && hits.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(18),
                      child: Text(t('map.search_empty'), style: TextStyle(fontSize: 14, height: 1.35, color: cs.onSurface.withValues(alpha: 0.55))),
                    ),
                  if (farOnly)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 4, 18, 2),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Icon(Icons.info_outline, size: 18, color: const Color(0xFFE3A13A)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            t('map.search_none_near'),
                            style: TextStyle(fontSize: 13.5, height: 1.35, color: cs.onSurface.withValues(alpha: 0.75)),
                          ),
                        ),
                      ]),
                    ),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.only(bottom: 8),
                      children: [
                        for (final hit in hits)
                          ListTile(
                            dense: true,
                            leading: CircleAvatar(
                              radius: 16,
                              backgroundColor: cs.primary.withValues(alpha: 0.10),
                              child: Icon(Icons.place_outlined, size: 18, color: cs.primary),
                            ),
                            title: Text(hit.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                            subtitle: Text(
                              [if (hit.detail.isNotEmpty) hit.detail, _kmText(hit.km)].join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12.5, color: cs.outline),
                            ),
                            onTap: () {
                              Navigator.of(ctx).pop();
                              _useHit(hit);
                            },
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            );
          },
        );
      },
    );
    debounce?.cancel();
  }

  /// A typed place becomes the destination and the route starts immediately.
  void _useHit(_SearchHit hit) {
    _routeSeq++; // any run of directions still in flight is irrelevant now
    setState(() {
      _toPick = LatLng(hit.lat, hit.lon);
      _toName = hit.name;
      _pickMode = null;
    });
    unawaited(_planRoute());
  }

  /// A place tapped in another tab (a nearby hospital or gym in the Health tab) becomes the
  /// destination and the route is planned at once. The map stays built inside the tab shell,
  /// so this works even while the Map tab is not the one on screen.
  void routeTo(LatLng dest, String name) {
    _routeSeq++; // any run of directions still in flight is irrelevant now
    setState(() {
      _toPick = dest;
      _toName = name;
      _pickMode = null;
    });
    unawaited(_planRoute());
    try {
      _map.move(dest, _map.camera.zoom < 12 ? 16 : _map.camera.zoom);
    } catch (_) {
      // The map is off-screen: the route fit that follows starts it regardless.
    }
  }

  // ---- directions: any point to any point ----

  /// Folds an OSRM route answer into a drawable, speakable plan. Used as it is, free, no key.
  /// [paceMps] replaces the router's minutes with an honest count for walking and cycling:
  /// the time is simply the path length walked or cycled at a normal Nigerian pace.
  static _RoutePlan _buildPlan(Map<String, dynamic> r, LatLng dest, String destName, {double? paceMps}) {
    final coords = ((r['geometry'] as Map<String, dynamic>)['coordinates'] ?? const <dynamic>[]) as List<dynamic>;
    final points = [for (final c in coords) LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble())];
    final km = (r['distance'] as num).toDouble() / 1000.0;
    final osrmMins = (((r['duration'] as num).toDouble()) / 60).round();
    final mins = paceMps == null ? osrmMins : ((km * 1000.0 / paceMps) / 60.0).ceil().clamp(1, 1440).toInt();
    final leg = (r['legs'] as List<dynamic>).first as Map<String, dynamic>;
    final stepTexts = <String>[];
    final stepSay = <String>[];
    final stepLocs = <LatLng>[];
    for (final raw in (leg['steps'] ?? const <dynamic>[]) as List<dynamic>) {
      final s = raw as Map<String, dynamic>;
      final m = s['maneuver'] as Map<String, dynamic>;
      final type = '${m['type']}';
      final modifier = m['modifier'] == null ? '' : '${m['modifier']}';
      final road = (s['name'] == null || '${s['name']}'.isEmpty) ? '' : ' to ${s['name']}';
      final metres = (s['distance'] as num).toDouble();
      final dist = metres < 950 ? '${metres.round()} m' : '${(metres / 1000).toStringAsFixed(1)} km';
      stepTexts.add('${_arrow(type, modifier)}$road - $dist');
      stepSay.add(_sayFor(type, modifier, road, metres));
      final loc = (m['location'] as List<dynamic>);
      stepLocs.add(LatLng((loc[1] as num).toDouble(), (loc[0] as num).toDouble()));
    }
    return _RoutePlan(points: points, dest: dest, destName: destName, km: km, mins: mins, stepTexts: stepTexts, stepLocs: stepLocs, stepSay: stepSay);
  }

  /// Draw the route: picked start to picked destination, or the phone's position to the
  /// picked destination, or (nothing picked) to the nearest police command's post. Every way of
  /// travelling plans on the same street map; the minutes come from travel pace, so walking and
  /// cycling read as a person's time, not a machine's.
  Future<void> _planRoute() async {
    final t = widget.i18n.t;
    final f = _fix;
    final dir = widget.police;
    final to = _toPick;
    if (f == null) {
      // Directions need a starting point. The phone has not settled on its position yet: say so
      // instead of doing nothing, with a Retry for once the GPS finds it.
      if (mounted && to != null) setState(() { _routeError = t('map.route_fix_gps'); _routeRetry = true; _routeBusy = false; });
      return;
    }
    if (to == null && dir == null) return;
    final seq = ++_routeSeq;
    setState(() { _routeBusy = true; _routeError = null; });
    try {
      LatLng from;
      LatLng dest;
      String destName;
      if (to != null) {
        from = _fromPick ?? LatLng(f.lat, f.lon);
        dest = to;
        destName = _toName ?? t('map.dropped');
      } else {
        final d = await dir!;
        final near = nearestPolice(d, f.lat, f.lon);
        if (near == null) {
          if (mounted) setState(() { _routeBusy = false; _routeError = t('police.none_found'); _routeRetry = false; });
          return;
        }
        final stateName = near.primary.command.state;
        final centre = stateCentres[stateName]!;
        from = LatLng(f.lat, f.lon);
        dest = LatLng(centre.$1, centre.$2);
        destName = t('map.to_police', {'state': stateName});
      }
      // Walking and cycling in Nigeria happen on the same streets cars use, and the free router's
      // separate foot/bike path maps are thin here - it once turned a 2 km street trip into a
      // 15 km "walk" through paths that exist only as mapping stubs (that was the impossible
      // "94 minutes"). So every mode plans on the real street map. Driving keeps the router's
      // own car minutes; walking and cycling get honest minutes from the path length at a normal
      // Nigerian pace (ambling 1.35 m/s, riding 4.17 m/s), so a 2 km trip never reads as hours.
      const slug = 'car';
      const headers = {'User-Agent': 'Sentri/0.1'};
      final query = '${from.longitude},${from.latitude};${dest.longitude},${dest.latitude}?overview=full&geometries=geojson&steps=true';
      Map<String, dynamic>? body;
      for (var attempt = 1; attempt <= 3 && body == null; attempt++) {
        if (attempt > 1) await Future.delayed(Duration(milliseconds: attempt == 2 ? 900 : 2200));
        try {
          final res = await http.get(Uri.parse('https://routing.openstreetmap.de/routed-$slug/route/v1/driving/$query'), headers: headers).timeout(const Duration(seconds: 20));
          if (res.statusCode != 200) continue;
          final parsed = jsonDecode(res.body);
          if (parsed is Map<String, dynamic> && parsed['routes'] is List && (parsed['routes'] as List).isNotEmpty) body = parsed;
        } catch (_) {}
      }
      if (body == null) {
        // The spare server: same free OSM street network, car-founded exactly like the main one
        // here, so the trip time it gives is as honest as the main one.
        try {
          final res = await http.get(Uri.parse('https://router.project-osrm.org/route/v1/driving/$query'), headers: headers).timeout(const Duration(seconds: 20));
          if (res.statusCode == 200) {
            final parsed = jsonDecode(res.body);
            if (parsed is Map<String, dynamic> && parsed['routes'] is List && (parsed['routes'] as List).isNotEmpty) body = parsed;
          }
        } catch (_) {}
      }
      if (body == null) {
        if (!mounted || seq != _routeSeq) return;
        setState(() { _routeBusy = false; _routeError = t('map.route_failed'); _routeRetry = true; });
        return;
      }
      final plan = _buildPlan(
        body['routes'].first as Map<String, dynamic>,
        dest,
        destName,
        paceMps: switch (_mode) { 'walking' => 1.35, 'cycling' => 4.17, _ => null },
      );
      if (!mounted || seq != _routeSeq) return;
      setState(() { _route = plan; _routeBusy = false; _nextStep = 0; _routeRetry = false; });
      if (_voiceOn) {
        await _voice.say(plan.destName);
        await _voice.say('${plan.kmText} , ${plan.mins} minutes');
        _speakNext(plan);
      }
      try {
        // Fit the whole route on screen once.
        final latitudes = [for (final p in plan.points) p.latitude];
        final longitudes = [for (final p in plan.points) p.longitude];
        final north = latitudes.reduce((a, b) => a > b ? a : b);
        final south = latitudes.reduce((a, b) => a < b ? a : b);
        final east = longitudes.reduce((a, b) => a > b ? a : b);
        final west = longitudes.reduce((a, b) => a < b ? a : b);
        final centre = LatLng((north + south) / 2, (east + west) / 2);
        _map.move(centre, _fitZoom(south, north).clamp(11.0, 16.0));
      } catch (_) {}
    } catch (_) {
      if (!mounted || seq != _routeSeq) return;
      setState(() { _routeBusy = false; _routeError = t('map.route_failed'); });
    }
  }

  double _fitZoom(double south, double north) {
    final span = north - south;
    if (span <= 0.01) return 16;
    if (span > 0.5) return 11;
    if (span > 0.2) return 12.5;
    if (span > 0.08) return 14;
    return 15.5;
  }

  Future<void> _clearRoute() async {
    await _posSub?.cancel();
    _posSub = null;
    await _voice.stop();
    if (mounted) setState(() { _route = null; _routeError = null; _routeRetry = false; _voiceOn = false; _nextStep = 0; });
  }

  // ---- picked points ----

  /// Long-press either fills the point type being picked, or drops a destination and routes at once.
  Future<void> _onLongPress(LatLng pt) async {
    final t = widget.i18n.t;
    final mode = _pickMode;
    if (mode == 'from') {
      final seq = ++_routeSeq;
      setState(() { _pickMode = null; _fromPick = pt; _fromName = t('map.dropped'); });
      _fromName = await _pointName(pt.latitude, pt.longitude);
      if (mounted && seq == _routeSeq) setState(() {});
      return;
    }
    // Default long-press: set the destination and route there right away.
    if (mounted) setState(() { _pickMode = null; _toPick = pt; _toName = t('map.dropped'); });
    _toName = await _pointName(pt.latitude, pt.longitude);
    if (mounted) setState(() {});
    await _planRoute();
  }

  void _startPick(String mode) {
    setState(() => _pickMode = _pickMode == mode ? null : mode);
  }

  void _clearPoints() {
    setState(() { _fromPick = null; _fromName = null; _toPick = null; _toName = null; _pickMode = null; });
    unawaited(_clearRoute());
  }

  // ---- the way of travelling ----

  /// Switch between car, foot and bike. A drawn route is redrawn for the new way of travelling,
  /// from the same start and destination, so the times change but nothing else does.
  void _setMode(String profile) {
    if (_mode == profile) return;
    _routeSeq++; // any run of directions still in flight is irrelevant now
    setState(() {
      _mode = profile;
      _route = null;
      _routeError = null;
      _routeRetry = false;
      _voiceOn = false;
      _nextStep = 0;
    });
    unawaited(_posSub?.cancel());
    _posSub = null;
    unawaited(_voice.stop());
    if (_toPick != null) unawaited(_planRoute());
  }

  /// One round travel-mode button, selected state filled in, like the modes on a navigator.
  Widget _modeChip(BuildContext context, String profile, IconData icon, String label) {
    final cs = Theme.of(context).colorScheme;
    final active = _mode == profile;
    return Tooltip(
      message: label,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => _setMode(profile),
        child: Semantics(
          button: true,
          selected: active,
          label: label,
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(shape: BoxShape.circle, color: active ? cs.primary : null),
            child: Icon(icon, size: 20, color: active ? Colors.white : cs.onSurface.withValues(alpha: 0.75)),
          ),
        ),
      ),
    );
  }

  // ---- spoken guidance ----

  void _toggleVoice() {
    final plan = _route;
    if (plan == null) return;
    setState(() {
      if (_voiceOn) {
        _voiceOn = false;
        unawaited(_voice.stop());
        unawaited(_posSub?.cancel());
        _posSub = null;
      } else {
        _voiceOn = true;
        _startVoice(plan);
      }
    });
  }

  Future<void> _startVoice(_RoutePlan plan) async {
    final t = widget.i18n.t;
    await _voice.say(t('map.voice_ready', {'name': plan.destName, 'km': plan.kmText, 'min': plan.minText}));
    _speakNext(plan);
    if (_posSub != null) return;
    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 8),
    ).listen((p) {
      final planL = _route;
      if (planL == null || !_voiceOn) return;
      _speakNext(planL, at: LatLng(p.latitude, p.longitude));
    }, onError: (Object _) {});
  }

  /// Each instruction is spoken as the maneuver point is reached.
  void _speakNext(_RoutePlan plan, {LatLng? at}) {
    final here = at;
    if (here == null) return; // no fix on hand: the next stream reading speaks
    final d = const Distance();
    while (_nextStep < plan.stepLocs.length && d(here, plan.stepLocs[_nextStep]) < 40) {
      final line = plan.stepSay[_nextStep];
      _nextStep++;
      if (line.isNotEmpty) unawaited(_voice.say(line));
    }
  }

  /// Street-level look of the spot: the Google Maps app is asked for Street View (a plain intent,
  /// no key and no billing); a browser street-view link is the fallback if the app is missing.
  Future<void> _streetView(GeoFix f) async {
    final app = Uri.parse('google.streetview:cbll=${f.lat},${f.lon}&cbp=0,0,,0,2&mz=19');
    var opened = false;
    try {
      opened = await launchUrl(app, mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }
    if (opened) return;
    try {
      await launchUrl(Uri.parse('https://www.google.com/maps/@?api=1&map_action=pano&viewpoint=${f.lat},${f.lon}'), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  void _showSteps() {
    final plan = _route;
    if (plan == null) return;
    final t = widget.i18n.t;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(padding: const EdgeInsets.fromLTRB(22, 4, 22, 10), child: Text(t('map.route_steps'), style: Theme.of(ctx).textTheme.titleMedium)),
            Padding(padding: const EdgeInsets.fromLTRB(22, 0, 22, 8), child: Text(plan.destName, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF6A5FF0)))),
            for (final s in plan.stepTexts)
              Padding(padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 6), child: Text(s, style: const TextStyle(fontSize: 15, height: 1.35))),
          ],
        ),
      ),
    );
  }

  /// Plain, calm words for a router maneuver, whatever the router calls it.
  static String _arrow(String type, String modifier) {
    if (type == 'depart') return 'Start';
    if (type == 'arrive') return 'Arrive';
    if (type == 'roundabout' || type == 'rotary') return 'Roundabout';
    switch (modifier) {
      case 'left':
        return 'Turn left';
      case 'right':
        return 'Turn right';
      case 'straight':
        return 'Go straight';
      case 'uturn':
        return 'Turn around';
      default:
        return 'Continue';
    }
  }

  /// Words the phone speaks for a maneuver: distances and road names, like a car navigator.
  static String _sayFor(String type, String modifier, String road, double metres) {
    final dist = metres < 60 ? '' : metres < 950 ? 'in ${metres.round()} metres ' : 'in ${(metres / 1000).toStringAsFixed(1)} kilometres ';
    final onto = road.replaceFirst(' to ', ' onto ');
    switch (type) {
      case 'depart':
        return 'Start$onto';
      case 'arrive':
        return 'You have arrived';
      case 'roundabout' || 'rotary':
        return 'At the roundabout$onto';
      case 'new name':
        return 'Continue straight$onto';
      case 'merge':
        return 'Merge$onto';
      case 'fork':
        return 'Keep $modifier$onto';
      case 'end of road':
        return 'At the end of the road, turn $modifier$onto';
    }
    switch (modifier) {
      case 'left':
        return '${dist}turn left$onto';
      case 'right':
        return '${dist}turn right$onto';
      case 'straight':
        return 'Continue straight$onto';
      case 'uturn':
        return 'Make a U-turn$onto';
      default:
        return 'Continue$onto';
    }
  }

  // ---- the look: map full-screen, icon buttons floating, one slim card below ----

  /// A round floating icon control, Google Maps style.
  Widget _fab(BuildContext context, {required IconData? icon, required String label, required VoidCallback? onTap, Color? iconColor, bool filled = false, Widget? child}) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: filled ? (iconColor ?? cs.primary) : (dark ? const Color(0xFF1B1D23) : Colors.white),
        shape: CircleBorder(side: BorderSide(color: filled ? Colors.transparent : (dark ? Colors.white.withValues(alpha: 0.18) : Colors.black.withValues(alpha: 0.08)))),
        elevation: 2,
        shadowColor: Colors.black26,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 46,
            height: 46,
            child: child ?? Icon(icon, size: 22, color: filled ? Colors.white : (iconColor ?? cs.primary)),
          ),
        ),
      ),
    );
  }

  /// "Accuracy ±12 m" pill: green when it is as good as a phone gets, amber so-so, red rough.
  String _accuracyText(GeoFix? f, String Function(String key, [Map<String, String> args]) t) {
    final m = f?.accuracyM;
    if (m == null) return t('map.finding');
    return t('map.accuracy', {'m': '${m.round()}'});
  }

  Color _accuracyColor(BuildContext context, GeoFix? f) {
    final m = f?.accuracyM;
    final cs = Theme.of(context).colorScheme;
    if (m == null) return cs.outline;
    if (m <= 30) return cs.tertiary;
    if (m <= 100) return const Color(0xFFE3A13A);
    return cs.error;
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.i18n.t;
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final f = _fix;
    final here = f == null ? const LatLng(9.0820, 7.4730) : LatLng(f.lat, f.lon);
    final p = _place;
    final topPad = MediaQuery.paddingOf(context).top;
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: FlutterMap(
              mapController: _map,
              options: MapOptions(
                initialCenter: here,
                initialZoom: f == null ? 5.5 : 17,
                onLongPress: (_, pt) => unawaited(_onLongPress(pt)),
              ),
              children: [
                TileLayer(urlTemplate: AppConfig.tileUrl, userAgentPackageName: 'ng.sentri.sentri'),
                if (f != null)
                  CircleLayer(circles: [
                    CircleMarker(point: here, radius: (f.accuracyM ?? 20), useRadiusInMeter: true, color: cs.primary.withValues(alpha: 0.15), borderColor: cs.primary.withValues(alpha: 0.4), borderStrokeWidth: 1),
                  ]),
                // Nearby places written on the map, the way Google Maps and Organic Maps draw
                // them: a small icon with the place's name right beside it.
                if (_near.isNotEmpty)
                  MarkerLayer(
                    markers: [
                      for (final n in _near.take(18))
                        Marker(
                          point: LatLng(n.lat, n.lon),
                          width: 140,
                          height: 46,
                          alignment: Alignment.bottomCenter,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                constraints: const BoxConstraints(maxWidth: 136),
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: dark ? const Color(0xDD18174D) : const Color(0xE6FFFFFF),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: dark ? Colors.white.withValues(alpha: 0.18) : Colors.black.withValues(alpha: 0.06)),
                                ),
                                child: Text(
                                  n.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 10.5, height: 1.1, fontWeight: FontWeight.w600, color: dark ? Colors.white : const Color(0xFF2B2B3A)),
                                ),
                              ),
                              Icon(_nearIcon(n.kind), size: 20, color: const Color(0xFF6A5FF0), shadows: const [Shadow(blurRadius: 4, color: Colors.white)]),
                            ],
                          ),
                        ),
                    ],
                  ),
                if (f != null)
                  MarkerLayer(markers: [
                    Marker(
                      point: here,
                      width: 28,
                      height: 28,
                      child: Container(decoration: BoxDecoration(color: cs.primary, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 4))),
                    ),
                  ]),
                if (_fromPick != null)
                  MarkerLayer(markers: [
                    Marker(
                      point: _fromPick!,
                      width: 34,
                      height: 34,
                      child: const Icon(Icons.trip_origin, size: 26, color: Color(0xFF2BB673), shadows: [Shadow(blurRadius: 6, color: Colors.white)]),
                    ),
                  ]),
                if (_toPick != null)
                  MarkerLayer(markers: [
                    Marker(
                      point: _toPick!,
                      width: 34,
                      height: 34,
                      child: const Icon(Icons.location_on, size: 30, color: Color(0xFFE2574C), shadows: [Shadow(blurRadius: 6, color: Colors.white)]),
                    ),
                  ]),
                if (_route != null)
                  PolylineLayer(polylines: [
                    Polyline(points: _route!.points, strokeWidth: 5, color: const Color(0xFF6A5FF0)),
                  ]),
                if (_route != null)
                  MarkerLayer(markers: [
                    Marker(
                      point: _route!.dest,
                      width: 34,
                      height: 34,
                      child: const Icon(Icons.flag, size: 30, color: Color(0xFF6A5FF0), shadows: [Shadow(blurRadius: 6, color: Colors.white)]),
                    ),
                  ]),
                const RichAttributionWidget(attributions: [TextSourceAttribution('© OpenStreetMap contributors'), TextSourceAttribution('© CARTO')]),
              ],
            ),
          ),

          // Address card, Google-style: what is under the pin, at the top.
          Positioned(
            top: topPad + 8,
            left: 12,
            right: 12,
            child: Column(children: [
              Material(
                color: dark ? const Color(0xFF1B1D23) : Colors.white,
                borderRadius: BorderRadius.circular(30),
                elevation: 3,
                shadowColor: Colors.black26,
                child: InkWell(
                  borderRadius: BorderRadius.circular(30),
                  onTap: () {
                    final fix = _fix;
                    if (fix == null) return;
                    try {
                      _map.move(LatLng(fix.lat, fix.lon), 17);
                    } catch (_) {}
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    child: Row(children: [
                      Icon(Icons.location_on, size: 22, color: cs.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(
                            _denied ? t('map.no_location') : (p?.street ?? p?.area ?? t('map.unknown_place')),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600),
                          ),
                          if (!_denied)
                            Text(
                              [if (p?.area != null) p!.area!, _accuracyText(f, t)].join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12, color: cs.onSurface.withValues(alpha: 0.55)),
                            ),
                        ]),
                      ),
                    ]),
                  ),
                ),
              ),
              // The hint while a start/destination pick is waiting for a long-press.
              if (_pickMode != null) ...[
                const SizedBox(height: 8),
                Material(
                  color: cs.primary,
                  borderRadius: BorderRadius.circular(30),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text(t('map.pick_hint'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.w500)),
                  ),
                ),
              ],
            ]),
          ),

          // Round action buttons along the right edge. While a destination/route is on the card
          // (the mode row makes the card taller) they lift a little, so nothing ever overlaps.
          Positioned(
            right: 10,
            bottom: MediaQuery.paddingOf(context).bottom + (_route != null || _toPick != null ? 168.0 : 118.0),
            child: Column(children: [
              _fab(context, icon: Icons.visibility_outlined, label: t('map.street_view'), onTap: f == null ? null : () => unawaited(_streetView(f))),
              const SizedBox(height: 10),
              _fab(
                context,
                icon: _routeBusy ? null : Icons.directions_outlined,
                label: t('map.directions'),
                onTap: () => unawaited(_searchDestination()),
                child: _routeBusy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : null,
              ),
              const SizedBox(height: 10),
              _fab(
                context,
                icon: Icons.trip_origin,
                label: _fromPick == null ? t('map.pick_start') : t('map.pick_start_set', {'name': _fromName ?? ''}),
                onTap: () => _startPick('from'),
                filled: _fromPick != null,
                iconColor: const Color(0xFF1F9A5B),
              ),
              const SizedBox(height: 10),
              _fab(
                context,
                icon: Icons.location_on_outlined,
                label: _toPick == null ? t('map.pick_end') : t('map.pick_end_set', {'name': _toName ?? ''}),
                onTap: () => _startPick('to'),
                filled: _toPick != null,
                iconColor: const Color(0xFFE2574C),
              ),
              const SizedBox(height: 10),
              _fab(context, icon: Icons.explore_outlined, label: t('map.nearby'), onTap: () => _showNearby(), iconColor: cs.onSurface),
            ]),
          ),

          // One slim card: the place, the route line, and nothing else.
          Positioned(
            left: 12,
            right: 12,
            bottom: MediaQuery.paddingOf(context).bottom + 8,
            child: Material(
              color: dark ? const Color(0xFF1B1D23) : Colors.white,
              borderRadius: BorderRadius.circular(20),
              elevation: 4,
              shadowColor: Colors.black26,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    // The dot: exact when green, amber when decent, red when only a rough area.
                    Icon(_fix == null ? Icons.gps_not_fixed : ((_fix!.accuracyM ?? 999) <= 30 ? Icons.gps_fixed : Icons.gps_not_fixed), size: 16, color: _accuracyColor(context, f)),
                    const SizedBox(width: 6),
                    Text(_accuracyText(f, t), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _accuracyColor(context, f))),
                    const Spacer(),
                    Text('${f?.lat.toStringAsFixed(5) ?? ''}, ${f?.lon.toStringAsFixed(5) ?? ''}', style: TextStyle(fontSize: 11.5, color: cs.onSurface.withValues(alpha: 0.5))),
                  ]),
                  if (_routeError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                        Icon(Icons.error_outline, size: 15, color: cs.error),
                        const SizedBox(width: 6),
                        Expanded(child: Text(_routeError!, style: TextStyle(fontSize: 12.5, height: 1.3, color: cs.error))),
                        if (_routeRetry)
                          TextButton(
                            onPressed: () => unawaited(_planRoute()),
                            style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 10), minimumSize: const Size(0, 32)),
                            child: Text(t('map.route_retry'), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                          ),
                      ]),
                    ),
                  // Travel modes: car, foot and bike, each with its own route and estimated time.
                  if (_route != null || _toPick != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6, bottom: 2),
                      child: Row(children: [
                        _modeChip(context, 'driving', Icons.directions_car, t('map.mode_car')),
                        const SizedBox(width: 6),
                        _modeChip(context, 'walking', Icons.directions_walk, t('map.mode_walk')),
                        const SizedBox(width: 6),
                        _modeChip(context, 'cycling', Icons.directions_bike, t('map.mode_bike')),
                      ]),
                    ),
                  if (_route != null) ...[
                    const SizedBox(height: 6),
                    Row(children: [
                      Container(width: 10, height: 10, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: const Color(0xFF6A5FF0), width: 3))),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(_route!.destName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
                          Text(t('map.route_info', {'km': _route!.kmText, 'min': _route!.minText}), style: TextStyle(fontSize: 12.5, color: cs.onSurface.withValues(alpha: 0.6))),
                        ]),
                      ),
                      IconButton(
                        tooltip: t('map.route_steps'),
                        onPressed: _showSteps,
                        icon: const Icon(Icons.list, size: 22, color: Color(0xFF6A5FF0)),
                      ),
                      IconButton(
                        tooltip: _voiceOn ? t('map.voice_off') : t('map.voice_on'),
                        onPressed: _toggleVoice,
                        icon: _voiceOn ? const Icon(Icons.volume_up, size: 22, color: Color(0xFF6A5FF0)) : const Icon(Icons.volume_off_outlined, size: 22, color: Color(0xFF6A5FF0)),
                      ),
                      IconButton(
                        tooltip: t('map.clear_point'),
                        onPressed: _clearPoints,
                        icon: Icon(Icons.close, size: 22, color: cs.onSurface.withValues(alpha: 0.6)),
                      ),
                    ]),
                  ],
                  if (_route == null && (f?.accuracyM ?? 0) > 100) ...[
                    const SizedBox(height: 6),
                    Text(t('map.approx_hint'), style: TextStyle(fontSize: 12, height: 1.3, color: cs.onSurface.withValues(alpha: 0.65))),
                    Row(children: [
                      TextButton(onPressed: () => unawaited(Geolocator.openLocationSettings()), child: Text(t('map.open_location_settings'))),
                      TextButton(onPressed: () => unawaited(Geolocator.openAppSettings()), child: Text(t('map.open_app_settings'))),
                    ]),
                  ],
                ]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
