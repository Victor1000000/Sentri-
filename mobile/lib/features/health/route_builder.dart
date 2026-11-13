import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../../core/config.dart';
import '../../core/i18n/i18n.dart';
import 'exercise_controller.dart';

/// A route the person built for themselves before a walk, run or ride: the points
/// they tapped (every street they want to pass through), folded into one real
/// street route by the same free router the directions use, with an honest
/// distance and a time that matches the chosen movement's pace.
class PlannedRoute {
  const PlannedRoute({required this.points, required this.km, required this.mins});
  final List<LatLng> points;
  final double km;
  final int mins;
}

/// The route builder, Strava's "build your own route" - on Sentri's map. Tap the
/// map once for every place the session should pass through; the route redraws
/// through all of them, with distance and minutes underneath. Undo takes the last
/// point back, Clear starts over, and "Use this route" carries the plan into the
/// session, where it is drawn as a dashed line the walked line grows along.
class RouteBuilderScreen extends StatefulWidget {
  const RouteBuilderScreen({super.key, required this.i18n, required this.mode, this.start});
  final I18n i18n;
  final ExerciseMode mode;

  /// Where to open the map: the phone's last known position when there is one.
  final LatLng? start;

  @override
  State<RouteBuilderScreen> createState() => _RouteBuilderState();
}

class _RouteBuilderState extends State<RouteBuilderScreen> {
  final _map = MapController();
  final _way = <LatLng>[];
  int _seq = 0;
  bool _busy = false;
  String? _error;
  List<LatLng>? _route;
  double _km = 0;
  int _mins = 0;

  static const _maxWaypoints = 12;
  static const _headers = {'User-Agent': 'Sentri/0.1'};

  @override
  void initState() {
    super.initState();
    if (widget.start != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          _map.move(widget.start!, 16);
        } catch (_) {}
      });
    } else {
      // No last-known position: ask the phone for a fresh one, so the builder opens
      // on the person's street instead of a whole-country view that looks broken.
      // Silent on refusal - the map stays at the wide view and every tap still works.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(() async {
          try {
            final p = await Geolocator.getCurrentPosition(
              locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 8)),
            );
            if (!mounted) return;
            _map.move(LatLng(p.latitude, p.longitude), 16);
          } catch (_) {}
        }());
      });
    }
  }

  double get _paceMps => switch (widget.mode) {
        ExerciseMode.walk => 1.35, // ambling
        ExerciseMode.run => 2.6, // an easy jog
        ExerciseMode.bike => 4.17, // a normal ride
      };

  void _addWay(LatLng pt) {
    if (_way.length >= _maxWaypoints) return;
    setState(() {
      _way.add(pt);
      _route = null;
      _error = null;
    });
    unawaited(_plan());
  }

  void _undo() {
    if (_way.isEmpty) return;
    setState(() {
      _way.removeLast();
      _route = null;
      _error = null;
    });
    unawaited(_plan());
  }

  void _clear() {
    _seq++; // a stale router answer must never land after a clear
    setState(() {
      _way.clear();
      _route = null;
      _error = null;
      _busy = false;
    });
  }

  Future<void> _useRoute() async {
    final r = _route;
    if (r == null || r.length < 2) return;
    Navigator.of(context).pop(PlannedRoute(points: r, km: _km, mins: _mins));
  }

  /// Folds the router's answer into the plan: one polyline through every waypoint.
  /// The real street map (the car-founded one) is used on purpose, exactly like the
  /// directions do: the router's foot/bike path maps are thin in Nigeria and once
  /// turned a 2 km street trip into a 15 km "walk" through mapping stubs. The
  /// minutes come from the path's length at the chosen movement's own pace.
  Future<void> _plan() async {
    if (_way.length < 2) return;
    final t = widget.i18n.t;
    final seq = ++_seq;
    setState(() => _busy = true);
    final query = _way.map((p) => '${p.longitude},${p.latitude}').join(';');
    Map<String, dynamic>? body;
    for (var attempt = 1; attempt <= 3 && body == null; attempt++) {
      if (attempt > 1) await Future<void>.delayed(Duration(milliseconds: attempt == 2 ? 900 : 2200));
      try {
        final res = await http.get(Uri.parse('https://routing.openstreetmap.de/routed-car/route/v1/driving/$query?overview=full&geometries=geojson&steps=false'), headers: _headers).timeout(const Duration(seconds: 20));
        if (res.statusCode != 200) continue;
        final parsed = jsonDecode(res.body);
        if (parsed is Map<String, dynamic> && parsed['routes'] is List && (parsed['routes'] as List).isNotEmpty) body = parsed;
      } catch (_) {}
    }
    if (body == null) {
      // The spare server: same free OSM street network.
      try {
        final res = await http.get(Uri.parse('https://router.project-osrm.org/route/v1/driving/$query?overview=full&geometries=geojson&steps=false'), headers: _headers).timeout(const Duration(seconds: 20));
        if (res.statusCode == 200) {
          final parsed = jsonDecode(res.body);
          if (parsed is Map<String, dynamic> && parsed['routes'] is List && (parsed['routes'] as List).isNotEmpty) body = parsed;
        }
      } catch (_) {}
    }
    if (!mounted || seq != _seq) return;
    if (body == null) {
      setState(() {
        _busy = false;
        _error = t('route.failed');
      });
      return;
    }
    final r = body['routes'].first as Map<String, dynamic>;
    final coords = ((r['geometry'] as Map<String, dynamic>)['coordinates'] ?? const <dynamic>[]) as List<dynamic>;
    final points = [for (final c in coords) LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble())];
    final km = (r['distance'] as num).toDouble() / 1000.0;
    final mins = ((km * 1000.0 / _paceMps) / 60.0).ceil().clamp(1, 1440).toInt();
    setState(() {
      _route = points;
      _km = km;
      _mins = mins;
      _busy = false;
      _error = null;
    });
    // Fit the whole route on screen once, the way directions do.
    try {
      final latitudes = [for (final p in points) p.latitude];
      final longitudes = [for (final p in points) p.longitude];
      final north = latitudes.reduce((a, b) => a > b ? a : b);
      final south = latitudes.reduce((a, b) => a < b ? a : b);
      final east = longitudes.reduce((a, b) => a > b ? a : b);
      final west = longitudes.reduce((a, b) => a < b ? a : b);
      _map.move(LatLng((north + south) / 2, (east + west) / 2), _fitZoom(south, north));
    } catch (_) {}
  }

  double _fitZoom(double south, double north) {
    final span = north - south;
    if (span <= 0.01) return 16;
    if (span > 0.5) return 11;
    if (span > 0.2) return 12.5;
    if (span > 0.08) return 14;
    return 15.5;
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.i18n.t;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.route_outlined, size: 20, color: Color(0xFF6A5FF0)),
          const SizedBox(width: 8),
          Text(t('route.build')),
        ]),
      ),
      body: Stack(children: [
        Positioned.fill(
          child: FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: widget.start ?? const LatLng(9.0820, 7.4730),
              initialZoom: widget.start == null ? 5.5 : 16,
              onTap: (_, pt) => _addWay(pt),
            ),
            children: [
              TileLayer(urlTemplate: AppConfig.tileUrl, userAgentPackageName: 'ng.sentri.sentri'),
              // While the router is thinking (or there are only two points not yet
              // answered), a dashed straight line previews the order of the taps.
              if (_route == null && _way.length >= 2)
                PolylineLayer(polylines: [
                  Polyline(
                    points: List<LatLng>.of(_way),
                    strokeWidth: 3,
                    color: const Color(0xFF6A5FF0).withValues(alpha: 0.55),
                    pattern: StrokePattern.dashed(segments: [8.0, 8.0]),
                  ),
                ]),
              if (_route != null)
                PolylineLayer(polylines: [
                  Polyline(points: _route!, strokeWidth: 5, color: const Color(0xFF6A5FF0)),
                ]),
              MarkerLayer(markers: [
                for (final (i, w) in _way.indexed)
                  Marker(
                    point: w,
                    width: 30,
                    height: 30,
                    child: Container(
                      decoration: BoxDecoration(
                        color: i == 0 ? const Color(0xFF2BB673) : const Color(0xFF6A5FF0),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 3),
                      ),
                    ),
                  ),
              ]),
              const RichAttributionWidget(attributions: [TextSourceAttribution('© OpenStreetMap contributors'), TextSourceAttribution('© CARTO')]),
            ],
          ),
        ),

        // The hint while the person is still tapping; the "drawing" note or the
        // honest error while the router answers.
        Positioned(
          left: 14,
          right: 14,
          top: 10,
          child: Column(children: [
            if (_busy)
              _pill(Row(mainAxisSize: MainAxisSize.min, children: [
                const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                const SizedBox(width: 9),
                Text(t('route.busy'), style: const TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.w600)),
              ]))
            else if (_error != null)
              _pill(Text(_error!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.w600)))
            else if (_way.isEmpty)
              _pill(Text(t('route.hint'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.w600))),
          ]),
        ),

        // The plan's numbers and the three controls, in one panel at the bottom.
        Positioned(
          left: 14,
          right: 14,
          bottom: MediaQuery.paddingOf(context).bottom + 14,
          child: Material(
            color: dark ? const Color(0xFF17181D) : Colors.white,
            borderRadius: BorderRadius.circular(24),
            elevation: 6,
            shadowColor: Colors.black38,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
              child: Column(children: [
                Row(children: [
                  Expanded(child: _stat(t('route.planned'), _route == null ? '--' : '${_km < 1 ? _km.toStringAsFixed(2) : _km.toStringAsFixed(1)} km')),
                  Expanded(child: _stat(t('exercise.time'), _route == null ? '--' : '~$_mins min')),
                  Expanded(child: _stat(t('route.waypoints'), '${_way.length}/$_maxWaypoints')),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  IconButton.outlined(
                    onPressed: _way.isEmpty ? null : _undo,
                    tooltip: t('route.undo'),
                    icon: const Icon(Icons.undo_rounded),
                  ),
                  const SizedBox(width: 8),
                  IconButton.outlined(
                    onPressed: _way.isEmpty ? null : _clear,
                    tooltip: t('route.clear'),
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                      onPressed: _route == null ? null : () => unawaited(_useRoute()),
                      icon: const Icon(Icons.check_rounded, size: 22),
                      label: Text(t('route.done'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ]),
              ]),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _pill(Widget child) => Material(
        color: Theme.of(context).colorScheme.primary,
        borderRadius: BorderRadius.circular(30),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: child,
        ),
      );

  Widget _stat(String label, String value) => Column(children: [
        Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
        const SizedBox(height: 2),
        Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55))),
      ]);
}
