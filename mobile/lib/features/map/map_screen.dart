import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart' show Geolocator;
import 'package:latlong2/latlong.dart';

import '../../core/config.dart';
import '../../core/i18n/i18n.dart';
import '../../core/net/api.dart';
import '../location/location.dart';
import '../location/place_lookup.dart';

/// Shows where the user is, on OpenStreetMap tiles, with the street, area, LGA and state.
/// The place name is a convenience: if the lookup fails the coordinates still show.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key, required this.location, required this.api, required this.i18n, this.placeLookup, this.onPlace, this.refresh = const Duration(seconds: 10)});
  final LocationSource location;
  final SentriApi api;
  final I18n i18n;

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
