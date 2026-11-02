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

/// Shows where the user is, on OpenStreetMap tiles, with the street, area, LGA and state.
/// The place name is a convenience: if the lookup fails the coordinates still show.
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
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
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
  int _routeSeq = 0;

  // -- picked points: directions work between any two spots on the map --
  LatLng? _fromPick;
  String? _fromName;
  LatLng? _toPick;
  String? _toName;
  String? _pickMode; // 'from' | 'to' while waiting for a long-press

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
      case 'petrol':
        return Icons.local_gas_station_outlined;
      case 'bank' || 'atm':
        return Icons.account_balance_outlined;
      case 'restaurant' || 'cafe' || 'bar' || 'food' || 'pub':
        return Icons.restaurant_outlined;
      case 'pharmacy':
        return Icons.medication_outlined;
      case 'school' || 'university':
        return Icons.school_outlined;
      case 'fuel':
        return Icons.local_gas_station_outlined;
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

  // ---- directions and street view ----

  /// Folds an OSRM route answer into a drawable, speakable plan. Used as it is, free, no key.
  static _RoutePlan _buildPlan(Map<String, dynamic> r, LatLng dest, String destName) {
    final coords = ((r['geometry'] as Map<String, dynamic>)['coordinates'] ?? const <dynamic>[]) as List<dynamic>;
    final points = [for (final c in coords) LatLng((c as List<dynamic>)[1] as double, c[0] as double)];
    final km = (r['distance'] as num).toDouble() / 1000.0;
    final mins = (((r['duration'] as num).toDouble()) / 60).round();
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
      stepLocs.add(LatLng(loc[1] as double, loc[0] as double));
    }
    return _RoutePlan(points: points, dest: dest, destName: destName, km: km, mins: mins, stepTexts: stepTexts, stepLocs: stepLocs, stepSay: stepSay);
  }

  /// Turn-by-turn through both open OSRM routers and spoken instructions.
  Future<void> _toggleRoute() async {
    final t = widget.i18n.t;
    if (_route != null) {
      await _clearRoute();
      return;
    }
    final f = _fix;
    final dir = widget.police;
    final to = _toPick;
    if (f == null) return;
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
          if (mounted) setState(() { _routeBusy = false; _routeError = t('police.none_found'); });
          return;
        }
        final stateName = near.primary.command.state;
        final centre = stateCentres[stateName]!;
        from = LatLng(f.lat, f.lon);
        dest = LatLng(centre.$1, centre.$2);
        destName = t('map.to_police', {'state': stateName});
      }
      final url = 'https://router.project-osrm.org/route/v1/driving/${from.longitude},${from.latitude};${dest.longitude},${dest.latitude}?overview=full&geometries=geojson&steps=true';
      final res = await http.get(Uri.parse(url), headers: const { 'User-Agent': 'Sentri/0.1' });
      if (res.statusCode != 200) throw StateError('osrm http ${res.statusCode}');
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final routes = (j['routes'] ?? const <dynamic>[]) as List<dynamic>;
      if (routes.isEmpty) throw StateError('osrm empty route');
      final plan = _buildPlan(routes.first as Map<String, dynamic>, dest, destName);
      if (!mounted || seq != _routeSeq) return;
      setState(() { _route = plan; _routeBusy = false; _nextStep = 0; });
      if (_voiceOn) {
        await _voice.say(plan.destName);
        await _voice.say('${plan.kmText} , ${plan.mins} minutes');
        _speakNext(plan);
      }
      try {
        final c = _map.camera;
        // Fit the whole route on screen once.
        final latitudes = [for (final p in plan.points) p.latitude];
        final longitudes = [for (final p in plan.points) p.longitude];
        final north = latitudes.reduce((a, b) => a > b ? a : b);
        final south = latitudes.reduce((a, b) => a < b ? a : b);
        final east = longitudes.reduce((a, b) => a > b ? a : b);
        final west = longitudes.reduce((a, b) => a < b ? a : b);
        final centre = LatLng((north + south) / 2, (east + west) / 2);
        final zoom = _fitZoom(south, north, c.zoom);
        _map.move(centre, zoom.clamp(11.0, 17.0));
      } catch (_) {}
    } catch (_) {
      if (!mounted || seq != _routeSeq) return;
      setState(() { _routeBusy = false; _routeError = t('map.route_failed'); });
    }
  }

  double _fitZoom(double south, double north, double current) {
    final span = north - south;
    if (span <= 0.01) return current;
    if (span > 0.5) return 11;
    if (span > 0.2) return 12.5;
    if (span > 0.08) return 14;
    return 15.5;
  }

  Future<void> _clearRoute() async {
    await _posSub?.cancel();
    _posSub = null;
    await _voice.stop();
    if (mounted) setState(() { _route = null; _routeError = null; _voiceOn = false; _nextStep = 0; });
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
    // Default long-press: set the destination (when no type was being picked, the same slot
    // in 'to' mode) and route there right away.
    if (mounted) setState(() { _pickMode = null; _toPick = pt; _toName = t('map.dropped'); });
    _toName = await _pointName(pt.latitude, pt.longitude);
    if (mounted) setState(() {});
    await _toggleRoute();
  }

  void _startPick(String mode) {
    setState(() => _pickMode = _pickMode == mode ? null : mode);
  }

  void _clearPoints() {
    setState(() { _fromPick = null; _fromName = null; _toPick = null; _toName = null; _pickMode = null; });
    unawaited(_clearRoute());
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

  /// The first instruction sits 40 m ahead of the spoken one and each after it comes as the
  /// maneuver point is reached.
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

  /// "Accuracy ±12 m" in green when it is as good as a phone gets, amber when so-so, red when it is only a rough area.
  Widget _accuracy(GeoFix f, ColorScheme cs, String Function(String key, [Map<String, String> args]) t) {
    final m = f.accuracyM;
    final good = m != null && m <= 30;
    final fair = m != null && m <= 100;
    final color = good ? cs.tertiary : (fair ? const Color(0xFFE3A13A) : cs.error);
    return Row(children: [
      Icon(good ? Icons.gps_fixed : Icons.gps_not_fixed, size: 14, color: color),
      const SizedBox(width: 4),
      Text(m == null ? t('map.finding') : t('map.accuracy', {'m': '${m.round()}'}), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
      if (!good) ...[const SizedBox(width: 8), Text(t('map.improving'), style: TextStyle(fontSize: 12, color: cs.outline))],
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.i18n.t;
    final cs = Theme.of(context).colorScheme;
    final f = _fix;
    final here = f == null ? const LatLng(9.0820, 7.4730) : LatLng(f.lat, f.lon);
    final p = _place;
    return Scaffold(
      appBar: AppBar(title: Text(t('tabs.map'))),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _map,
                  options: MapOptions(
                    initialCenter: here,
                    initialZoom: f == null ? 5.5 : 17,
                    onLongPress: (_, pt) => unawaited(_onLongPress(pt)),
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: AppConfig.tileUrl,
                      subdomains: const ['a', 'b', 'c', 'd'],
                      userAgentPackageName: 'ng.sentri.sentri',
                    ),
                    if (f != null)
                      CircleLayer(circles: [
                        CircleMarker(point: here, radius: (f.accuracyM ?? 20), useRadiusInMeter: true, color: cs.primary.withValues(alpha: 0.15), borderColor: cs.primary.withValues(alpha: 0.4), borderStrokeWidth: 1),
                      ]),
                    if (f != null)
                      MarkerLayer(markers: [
                        Marker(
                          point: here,
                          width: 28,
                          height: 28,
                          child: Container(decoration: BoxDecoration(color: cs.primary, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 4))),
                        ),
                      ]),
                    MarkerLayer(
                      markers: [
                        for (final n in _near)
                          Marker(
                            point: LatLng(n.lat, n.lon),
                            width: 30,
                            height: 30,
                            child: Icon(_nearIcon(n.kind), size: 20, color: const Color(0xFF6A5FF0), shadows: const [Shadow(blurRadius: 4, color: Colors.white)]),
                          ),
                      ],
                    ),
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
                if (_pickMode != null)
                  Positioned(
                    top: 12,
                    left: 20,
                    right: 20,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(color: cs.surface.withValues(alpha: 0.95), borderRadius: BorderRadius.circular(14), border: Border.all(color: cs.outlineVariant)),
                      child: Text(t('map.pick_hint'), style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600), textAlign: TextAlign.center),
                    ),
                  ),
              ],
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            decoration: BoxDecoration(color: cs.surface, border: Border(top: BorderSide(color: cs.outlineVariant))),
            child: SafeArea(
              top: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_denied)
                    Text(t('map.no_location'))
                  else if (f == null)
                    Text(t('map.finding'))
                  else ...[
                    Text(t('map.you_are_at'), style: TextStyle(fontSize: 12, color: cs.outline)),
                    const SizedBox(height: 2),
                    Text(p?.street ?? p?.area ?? t('map.unknown_place'), style: Theme.of(context).textTheme.titleMedium),
                    if (p != null)
                      Text([p.area, if (p.lga != null) '${p.lga} LGA', if (p.state != null) '${p.state} State'].whereType<String>().join(', ')),
                    if (p?.landmark != null) Text(t('map.near', {'name': p!.landmark!}), style: TextStyle(fontSize: 13, color: cs.outline)),
                    const SizedBox(height: 6),
                    _accuracy(f, cs, t),
                    Text('${f.lat.toStringAsFixed(5)}, ${f.lon.toStringAsFixed(5)}', style: TextStyle(fontSize: 12, color: cs.outline)),
                    const SizedBox(height: 8),
                    Wrap(alignment: WrapAlignment.start, spacing: 10, runSpacing: 6, children: [
                      OutlinedButton.icon(
                        onPressed: () => unawaited(_streetView(f)),
                        icon: const Icon(Icons.visibility_outlined, size: 18),
                        label: Text(t('map.street_view')),
                      ),
                      OutlinedButton.icon(
                        onPressed: widget.police == null && _toPick == null ? null : () => unawaited(_toggleRoute()),
                        icon: _routeBusy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.directions_outlined, size: 18),
                        label: Text(t('map.directions')),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _startPick('from'),
                        icon: const Icon(Icons.trip_origin, size: 16, color: Color(0xFF2BB673)),
                        label: Text(_fromPick == null ? t('map.pick_start') : t('map.pick_start_set', {'name': _fromName ?? ''})),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _startPick('to'),
                        icon: const Icon(Icons.location_on_outlined, size: 16, color: Color(0xFFE2574C)),
                        label: Text(_toPick == null ? t('map.pick_end') : t('map.pick_end_set', {'name': _toName ?? ''})),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _showNearby(),
                        icon: const Icon(Icons.travel_explore_outlined, size: 18),
                        label: Text(t('map.nearby')),
                      ),
                      if (_fromPick != null || _toPick != null)
                        IconButton(
                          tooltip: t('map.clear_point'),
                          onPressed: _clearPoints,
                          icon: const Icon(Icons.clear, size: 18),
                        ),
                    ]),
                    if (_routeError != null)
                      Padding(padding: const EdgeInsets.only(top: 8), child: Text(_routeError!, style: TextStyle(fontSize: 12.5, color: cs.error))),
                    if (_route != null) ...[
                      const SizedBox(height: 10),
                      Text(_route!.destName, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF6A5FF0))),
                      Row(children: [
                        Text(t('map.route_info', {'km': _route!.kmText, 'min': _route!.minText}), style: TextStyle(fontSize: 13, color: cs.outline)),
                        const Spacer(),
                        TextButton(onPressed: _showSteps, child: Text(t('map.route_steps'))),
                        IconButton(
                          tooltip: _voiceOn ? t('map.voice_off') : t('map.voice_on'),
                          onPressed: _toggleVoice,
                          icon: _voiceOn ? const Icon(Icons.volume_off, size: 18, color: Color(0xFF6A5FF0)) : const Icon(Icons.volume_up, size: 18),
                        ),
                      ]),
                    ],
                    if ((f.accuracyM ?? 0) > 60) ...[
                      const SizedBox(height: 8),
                      Text(t('map.approx_hint'), style: const TextStyle(fontSize: 12.5, height: 1.35)),
                      Row(children: [
                        TextButton(onPressed: () => unawaited(Geolocator.openLocationSettings()), child: Text(t('map.open_location_settings'))),
                        TextButton(onPressed: () => unawaited(Geolocator.openAppSettings()), child: Text(t('map.open_app_settings'))),
                      ]),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
