import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart' show Geolocator;
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

/// One planned route from the router: the line to draw, what it costs, and the step texts.
class _RoutePlan {
  const _RoutePlan({required this.points, required this.dest, required this.destName, required this.km, required this.mins, required this.stepTexts});
  final List<LatLng> points;
  final LatLng dest;
  final String destName;
  final double km;
  final int mins;
  final List<String> stepTexts;
  String get kmText => km >= 10 ? km.round().toString() : km.toStringAsFixed(1);
  String get minText => '$mins';
}

/// Shows where the user is, on OpenStreetMap tiles, with the street, area, LGA and state.
/// The place name is a convenience: if the lookup fails the coordinates still show.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key, required this.location, required this.api, required this.i18n, this.placeLookup, this.onPlace, this.refresh = const Duration(seconds: 10), this.police});
  final LocationSource location;
  final SentriApi api;
  final I18n i18n;

  /// The police commands, parsed once by the app shell. The directions button aims at the closest
  /// command's post. Null: the button then stays disabled.
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

  @override
  void initState() {
    super.initState();
    unawaited(_update());
    _timer = Timer.periodic(widget.refresh, (_) => unawaited(_update()));
  }

  @override
  void dispose() {
    _timer?.cancel();
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
      final f = await widget.location.preciseFix(timeout: const Duration(seconds: 20));
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

  // ---- directions and street view ----

  /// Show or clear the route to the closest police command's post. The route comes from the open
  /// OSRM router: free, no key, drawn straight from the answer. Undoing is a second tap.
  Future<void> _toggleRoute() async {
    final t = widget.i18n.t;
    if (_route != null) {
      setState(() { _route = null; _routeError = null; });
      return;
    }
    final f = _fix;
    final dir = widget.police;
    if (f == null || dir == null) return;
    final seq = ++_routeSeq;
    setState(() { _routeBusy = true; _routeError = null; });
    try {
      final d = await dir;
      final near = nearestPolice(d, f.lat, f.lon);
      if (near == null) {
        if (mounted) setState(() { _routeBusy = false; _routeError = t('police.none_found'); });
        return;
      }
      final stateName = near.primary.command.state;
      final centre = stateCentres[stateName]!;
      final dest = LatLng(centre.$1, centre.$2);
      final url = 'https://router.project-osrm.org/route/v1/driving/${f.lon},${f.lat};${dest.longitude},${dest.latitude}?overview=full&geometries=geojson&steps=true';
      final res = await http.get(Uri.parse(url), headers: const { 'User-Agent': 'Sentri/0.1' });
      if (res.statusCode != 200) throw StateError('osrm http ${res.statusCode}');
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final routes = (j['routes'] ?? const <dynamic>[]) as List<dynamic>;
      if (routes.isEmpty) throw StateError('osrm empty route');
      final r = routes.first as Map<String, dynamic>;
      final coords = ((r['geometry'] as Map<String, dynamic>)['coordinates'] ?? const <dynamic>[]) as List<dynamic>;
      final points = [for (final c in coords) LatLng((c as List<dynamic>)[1] as double, c[0] as double)];
      final km = (r['distance'] as num).toDouble() / 1000.0;
      final mins = (((r['duration'] as num).toDouble()) / 60).round();
      final leg = (r['legs'] as List<dynamic>).first as Map<String, dynamic>;
      final stepTexts = <String>[];
      for (final raw in (leg['steps'] ?? const <dynamic>[]) as List<dynamic>) {
        final s = raw as Map<String, dynamic>;
        final m = s['maneuver'] as Map<String, dynamic>;
        final type = '${m['type']}';
        final modifier = m['modifier'] == null ? '' : '${m['modifier']}';
        final road = (s['name'] == null || '${s['name']}'.isEmpty) ? '' : ' to ${s['name']}';
        final metres = (s['distance'] as num).toDouble();
        final dist = metres < 950 ? '${metres.round()} m' : '${(metres / 1000).toStringAsFixed(1)} km';
        stepTexts.add('${_arrow(type, modifier)}$road - $dist');
      }
      final plan = _RoutePlan(
        points: points,
        dest: dest,
        destName: t('map.to_police', {'state': stateName}),
        km: km,
        mins: mins,
        stepTexts: stepTexts,
      );
      if (!mounted || seq != _routeSeq) return;
      setState(() { _route = plan; _routeBusy = false; });
    } catch (_) {
      if (!mounted || seq != _routeSeq) return;
      setState(() { _routeBusy = false; _routeError = t('map.route_failed'); });
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
  String _arrow(String type, String modifier) {
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
            child: FlutterMap(
              mapController: _map,
              options: MapOptions(initialCenter: here, initialZoom: f == null ? 5.5 : 17),
              children: [
                TileLayer(urlTemplate: AppConfig.tileUrl, userAgentPackageName: 'ng.sentri.sentri'),
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
                      child: const Icon(Icons.local_police, size: 30, color: Color(0xFF6A5FF0), shadows: [Shadow(blurRadius: 6, color: Colors.white)]),
                    ),
                  ]),
                const RichAttributionWidget(attributions: [TextSourceAttribution('© OpenStreetMap contributors')]),
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
                        onPressed: widget.police == null ? null : () => unawaited(_toggleRoute()),
                        icon: _routeBusy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.directions_outlined, size: 18),
                        label: Text(t('map.directions')),
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
                      ]),
                    ],
                    if ((f.accuracyM ?? 0) > 100) ...[
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
