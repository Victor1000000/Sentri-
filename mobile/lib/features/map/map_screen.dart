import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/config.dart';
import '../../core/i18n/i18n.dart';
import '../../core/net/api.dart';
import '../location/location.dart';

/// Shows where the user is, on OpenStreetMap tiles, with the street, area, LGA and state.
/// The place name is a convenience: if the lookup fails the coordinates still show.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key, required this.location, required this.api, required this.i18n, this.onPlace, this.refresh = const Duration(seconds: 15)});
  final LocationSource location;
  final SentriApi api;
  final I18n i18n;
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

  Future<void> _update() async {
    final f = await widget.location.fix(highAccuracy: true, timeout: const Duration(seconds: 8)) ?? await widget.location.lastKnown();
    if (!mounted) return;
    if (f == null) {
      setState(() => _denied = _fix == null);
      return;
    }
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
      final seq = ++_lookupSeq;
      Place? p;
      try {
        p = await widget.api.reverseGeocode(f.lat, f.lon);
      } catch (_) {
        p = null;
      }
      if (!mounted || seq != _lookupSeq) return;
      setState(() => _place = p ?? _place);
      widget.onPlace?.call(_place);
    }
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
                    const SizedBox(height: 6),
                    Text('${f.lat.toStringAsFixed(5)}, ${f.lon.toStringAsFixed(5)}  ±${(f.accuracyM ?? 0).round()} m', style: TextStyle(fontSize: 12, color: cs.outline)),
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
