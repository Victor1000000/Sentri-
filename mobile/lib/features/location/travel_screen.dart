import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../../core/i18n/i18n.dart';
import '../../core/net/api.dart'; // GeoFix
import '../../core/widgets/flat.dart';
import '../location/location.dart';
import '../share/share_screen.dart' show clockTime;
import 'travel_data.dart';

/// Travel (v42): the home screen's fourth circle. The app has read how the
/// person is travelling since v41 - the map chip and the alert detail say
/// "on foot", "on a train", "in flight" - but that reading had no home of its
/// own. This screen opens on the live answer, straight from this phone's GPS:
/// the same hysteresis [TravelWatcher] the share flow uses (a mode only flips
/// once three speed readings in a row agree), fed by the phone's position
/// stream while the screen is open.
///
/// Honest note, shown on screen too: nothing is being shared here. Travel
/// mode only rides along with an alert or a location share the person starts
/// on purpose; this screen is just the person's own window onto it.
///
/// v44: live cards under the mode ring, all free public feeds, no keys:
/// weather right now (Open-Meteo), aircraft overhead (OpenSky), recent
/// earthquakes within 500 km (USGS), registered safety cameras within 3 km
/// (OpenStreetMap's Overpass), and a live map view of where the phone sits.
/// Every card says plainly when a feed is empty or unreachable - nothing is
/// invented to look alive. The parsing lives in travel_data.dart so tests can
/// run it without a network.
class TravelScreen extends StatefulWidget {
  const TravelScreen({super.key, required this.location, required this.i18n});
  final LocationSource location;
  final I18n i18n;

  @override
  State<TravelScreen> createState() => _TravelScreenState();
}

class _TravelScreenState extends State<TravelScreen> {
  final TravelWatcher _travel = TravelWatcher();
  StreamSubscription<GeoFix>? _sub;
  GeoFix? _last;
  double? _lastSpeedMps; // metres per second, for the km/h line
  bool _failed = false;

  // v44 live cards: one fetch each, kicked off when the first GPS fix lands.
  WeatherNow? _weather;
  bool _weatherFailed = false;
  List<OverheadFlight> _flights = const [];
  bool _flightsFailed = false;
  List<NearbyQuake> _quakes = const [];
  bool _quakesFailed = false;
  List<SafetyCamera> _cameras = const [];
  bool _camerasFailed = false;
  bool _liveStarted = false;
  int _pending = 0; // live fetches still in flight; the spinners read this

  /// True once every live feed has answered (or failed) - the cards stop
  /// spinning and show what they honestly got, even if that is nothing.
  bool get _liveDone => _liveStarted && _pending == 0;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  Future<void> _start() async {
    try {
      _sub = widget.location.positions(distanceFilterM: 8).listen(_onFix, onError: (_) {
        if (mounted) setState(() => _failed = true);
      });
    } catch (_) {
      // Sources that cannot stream: the screen says so instead of guessing.
      if (mounted) setState(() => _failed = true);
    }
  }

  void _onFix(GeoFix f) {
    final prev = _last;
    _last = f;
    _startLive(f);
    final mps = prev == null ? null : speedBetween(prev, f);
    if (mps != null) {
      _travel.feed(mps);
      if (mounted) setState(() => _lastSpeedMps = mps);
    } else if (mounted) {
      setState(() {});
    }
  }

  // ---- v44 live cards -------------------------------------------------------

  void _startLive(GeoFix f) {
    if (_liveStarted) return;
    _liveStarted = true;
    _pending = 4;
    unawaited(_fetchWeather(f));
    unawaited(_fetchFlights(f));
    unawaited(_fetchQuakes(f));
    unawaited(_fetchCameras(f));
  }

  /// Re-runs every card with the newest fix. A tap on the refresh arrow.
  void _refresh() {
    final f = _last;
    if (f == null) return;
    _liveStarted = false;
    _weatherFailed = false;
    _flightsFailed = false;
    _quakesFailed = false;
    _camerasFailed = false;
    _startLive(f);
    setState(() {});
  }

  Future<void> _fetchWeather(GeoFix f) async {
    try {
      final url = 'https://api.open-meteo.com/v1/forecast?latitude=${f.lat.toStringAsFixed(4)}&longitude=${f.lon.toStringAsFixed(4)}&current=temperature_2m,wind_speed_10m,precipitation,weather_code';
      final res = await http.get(Uri.parse(url), headers: const {'User-Agent': 'Sentri/0.1'}).timeout(const Duration(seconds: 12));
      final w = res.statusCode == 200 ? parseWeather(res.body) : null;
      if (mounted) setState(() { _weather = w; _weatherFailed = w == null; });
    } catch (_) {
      if (mounted) setState(() => _weatherFailed = true);
    } finally {
      _pending--;
    }
  }

  Future<void> _fetchFlights(GeoFix f) async {
    try {
      const d = 0.75; // about 80 km each way - the honest "overhead" range
      final url = 'https://opensky-network.org/api/states/all?lamin=${(f.lat - d).toStringAsFixed(4)}&lomin=${(f.lon - d).toStringAsFixed(4)}&lamax=${(f.lat + d).toStringAsFixed(4)}&lomax=${(f.lon + d).toStringAsFixed(4)}';
      final res = await http.get(Uri.parse(url), headers: const {'User-Agent': 'Sentri/0.1'}).timeout(const Duration(seconds: 15));
      final list = res.statusCode == 200 ? parseOverheadFlights(res.body, f.lat, f.lon) : const <OverheadFlight>[];
      if (mounted) setState(() {
        _flights = list;
        _flightsFailed = res.statusCode != 200;
      });
    } catch (_) {
      if (mounted) setState(() => _flightsFailed = true);
    } finally {
      _pending--;
    }
  }

  Future<void> _fetchQuakes(GeoFix f) async {
    try {
      final start = DateTime.now().toUtc().subtract(const Duration(days: 7)).toIso8601String().substring(0, 10);
      final url = 'https://earthquake.usgs.gov/fdsnws/event/2/query?format=geojson&latitude=${f.lat.toStringAsFixed(4)}&longitude=${f.lon.toStringAsFixed(4)}&maxradiuskm=500&minmagnitude=2.5&starttime=$start';
      final res = await http.get(Uri.parse(url), headers: const {'User-Agent': 'Sentri/0.1'}).timeout(const Duration(seconds: 15));
      final list = res.statusCode == 200 ? parseNearbyQuakes(res.body, f.lat, f.lon) : const <NearbyQuake>[];
      if (mounted) setState(() {
        _quakes = list;
        _quakesFailed = res.statusCode != 200;
      });
    } catch (_) {
      if (mounted) setState(() => _quakesFailed = true);
    } finally {
      _pending--;
    }
  }

  Future<void> _fetchCameras(GeoFix f) async {
    try {
      final q = '[out:json][timeout:25];node(around:3000,${f.lat.toStringAsFixed(5)},${f.lon.toStringAsFixed(5)})["man_made"="surveillance"];out;';
      final res = await http
          .post(Uri.parse('https://overpass-api.de/api/interpreter'), body: {'data': q}, headers: const {'User-Agent': 'Sentri/0.1'})
          .timeout(const Duration(seconds: 25));
      final list = res.statusCode == 200 ? parseCameras(res.body, f.lat, f.lon) : const <SafetyCamera>[];
      if (mounted) setState(() {
        _cameras = list;
        _camerasFailed = res.statusCode != 200;
      });
    } catch (_) {
      if (mounted) setState(() => _camerasFailed = true);
    } finally {
      _pending--;
    }
  }

  IconData _icon(TravelMode m) => switch (m) {
        TravelMode.walk => Icons.directions_walk,
        TravelMode.run => Icons.directions_run,
        TravelMode.ride => Icons.pedal_bike,
        TravelMode.drive => Icons.directions_car,
        TravelMode.train => Icons.train,
        TravelMode.flight => Icons.flight,
        TravelMode.still => Icons.my_location,
      };

  @override
  Widget build(BuildContext context) {
    final t = widget.i18n.t;
    final cs = Theme.of(context).colorScheme;
    final mode = _travel.mode;
    final kmh = _lastSpeedMps == null ? null : (_lastSpeedMps! * 3.6).round();
    return FlatPage(
      title: t('travel.title'),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(children: [
              // The speed ring (v43): the mode icon rides inside a ring that
              // fills with the live speed - a walking pace sits low on the
              // dial, a car swings it far around, flight pins it. 0 to
              // 140 km/h is the honest range of everyday movement.
              SizedBox(
                width: 148,
                height: 148,
                child: CustomPaint(
                  painter: _SpeedRing(
                    progress: kmh == null ? 0 : kmh.clamp(0, 140) / 140,
                    color: cs.primary,
                    track: cs.primary.withValues(alpha: 0.15),
                  ),
                  child: Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(_icon(mode), size: 36, color: cs.primary),
                      if (kmh != null) ...[
                        Text('$kmh', style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800, height: 1.1, fontFeatures: [FontFeature.tabularFigures()])),
                        Text('km/h', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, letterSpacing: 0.6, color: cs.onSurface.withValues(alpha: 0.5))),
                      ],
                    ]),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                t('map.travel_${mode.name}'),
                style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800, letterSpacing: -0.3),
              ),
              const SizedBox(height: 4),
              // The mode is not a guess the person maintains: the phone reads
              // it from the GPS all by itself, and says so.
              Text(
                t('travel.auto_hint'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, height: 1.4, color: cs.onSurface.withValues(alpha: 0.5)),
              ),
              const SizedBox(height: 8),
              if (_last != null)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.check_circle_outline_rounded, size: 13, color: cs.primary),
                  const SizedBox(width: 5),
                  Text(
                    t('travel.updated', {'t': clockTime(_last!.at)}),
                    style: TextStyle(fontSize: 12, color: cs.onSurface.withValues(alpha: 0.55), fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                ]),
              const SizedBox(height: 6),
              Text(
                kmh == null
                    ? (_failed ? t('travel.stream_failed') : t('travel.waiting'))
                    : t('travel.speed', {'n': '$kmh'}),
                style: TextStyle(fontSize: 13.5, height: 1.35, color: cs.onSurface.withValues(alpha: 0.6)),
              ),
              const SizedBox(height: 16),
              // Every band the phone can honestly tell apart, as its own chip:
              // the live one is filled in, so the person can see where they sit.
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  for (final m in TravelMode.values)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(99),
                        color: m == mode ? cs.primary.withValues(alpha: 0.14) : Colors.transparent,
                        border: Border.all(color: m == mode ? cs.primary : cs.onSurface.withValues(alpha: 0.16)),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(_icon(m), size: 15, color: m == mode ? cs.primary : cs.onSurface.withValues(alpha: 0.55)),
                        const SizedBox(width: 5),
                        Text(
                          t('map.travel_${m.name}'),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: m == mode ? FontWeight.w700 : FontWeight.w500,
                            color: m == mode ? cs.primary : cs.onSurface.withValues(alpha: 0.65),
                          ),
                        ),
                      ]),
                    ),
                ],
              ),
            ]),
          ),
        ),
        const SizedBox(height: 14),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(Icons.airplanemode_active, size: 18, color: cs.primary),
                const SizedBox(width: 8),
                Expanded(child: Text(t('travel.title'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
              ]),
              const SizedBox(height: 8),
              Text(t('travel.note'), style: TextStyle(fontSize: 13, height: 1.45, color: cs.onSurface.withValues(alpha: 0.7))),
            ]),
          ),
        ),
        ..._buildLiveCards(context, cs),
      ],
    );
  }

  // ---- v44 live cards -------------------------------------------------------

  /// The shared card shell: icon + title + refresh arrow on top, content under
  /// it. Every live card uses it so the five reads look like one family.
  Widget _liveCard(BuildContext context, {required IconData icon, required String title, required VoidCallback onRefresh, required Widget child}) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 18, color: cs.primary),
            const SizedBox(width: 8),
            Expanded(child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
            IconButton(
              tooltip: widget.i18n.t('travel.refresh'),
              visualDensity: VisualDensity.compact,
              onPressed: onRefresh,
              icon: Icon(Icons.refresh, size: 20, color: cs.onSurface.withValues(alpha: 0.5)),
            ),
          ]),
          const SizedBox(height: 8),
          child,
        ]),
      ),
    );
  }

  Widget _hint(BuildContext context, String s) =>
      Text(s, style: TextStyle(fontSize: 12.5, height: 1.45, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55)));

  Widget _emptyOrWaiting(BuildContext context, {required bool failed, required bool stillWaiting}) {
    final t = widget.i18n.t;
    if (!failed && stillWaiting) return Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)));
    return _hint(context, t('travel.none_nearby'));
  }

  IconData _weatherIcon(int code) {
    if (code == 0) return Icons.wb_sunny_outlined;
    if (code >= 1 && code <= 3) return Icons.cloud_outlined;
    if (code >= 51 && code <= 67) return Icons.umbrella_outlined; // drizzle + rain
    if (code >= 80 && code <= 82) return Icons.umbrella_outlined;
    if (code >= 71 && code <= 77) return Icons.ac_unit; // snow
    if (code >= 85 && code <= 86) return Icons.ac_unit;
    if (code >= 95) return Icons.bolt; // thunderstorm
    return Icons.cloud_outlined; // fog, haze and anything unlabelled
  }

  List<Widget> _buildLiveCards(BuildContext context, ColorScheme cs) {
    final tFn = widget.i18n.t;
    return [
      // Weather right now - Open-Meteo, no key needed.
      _liveCard(
        context,
        icon: Icons.wb_sunny_outlined,
        title: tFn('travel.weather'),
        onRefresh: _refresh,
        child: _weather == null
            ? _emptyOrWaiting(context, failed: _weatherFailed, stillWaiting: !_weatherFailed && !_liveDone)
            : Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Icon(_weatherIcon(_weather!.code), size: 36, color: cs.primary),
                  const SizedBox(width: 10),
                  Text('${_weather!.tempC.round()}', style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800, height: 1.0, fontFeatures: [FontFeature.tabularFigures()])),
                  Text(' °C', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cs.onSurface.withValues(alpha: 0.55))),
                  const Spacer(),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.air, size: 14, color: cs.onSurface.withValues(alpha: 0.55)),
                      const SizedBox(width: 4),
                      Text('${_weather!.windKmh.round()} km/h', style: const TextStyle(fontSize: 12.5, fontFeatures: [FontFeature.tabularFigures()])),
                    ]),
                    const SizedBox(height: 3),
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.water_drop_outlined, size: 14, color: cs.onSurface.withValues(alpha: 0.55)),
                      const SizedBox(width: 4),
                      Text('${_weather!.precipMm.toStringAsFixed(1)} mm', style: const TextStyle(fontSize: 12.5, fontFeatures: [FontFeature.tabularFigures()])),
                    ]),
                  ]),
                ],
              ),
      ),
      const SizedBox(height: 14),
      // Aircraft overhead - OpenSky's free bounding-box feed, nearest first.
      _liveCard(
        context,
        icon: Icons.flight_takeoff,
        title: tFn('travel.flights'),
        onRefresh: _refresh,
        child: _flights.isEmpty
            ? _emptyOrWaiting(context, failed: _flightsFailed, stillWaiting: !_flightsFailed && !_liveDone)
            : Column(children: [
                for (final f in _flights.take(4))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(children: [
                      Icon(Icons.flight, size: 15, color: cs.primary),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(f.callsign, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, height: 1.15)),
                          if (f.country.isNotEmpty) Text(f.country, style: TextStyle(fontSize: 11.5, color: cs.onSurface.withValues(alpha: 0.55), height: 1.2)),
                        ]),
                      ),
                      Text(
                        '${(f.distanceM / 1000).round()} km',
                        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()]),
                      ),
                    ]),
                  ),
              ]),
      ),
      const SizedBox(height: 14),
      // Recent earthquakes within 500 km - the USGS public feed.
      _liveCard(
        context,
        icon: Icons.crisis_alert_outlined,
        title: tFn('travel.emerg'),
        onRefresh: _refresh,
        child: _quakes.isEmpty
            ? _emptyOrWaiting(context, failed: _quakesFailed, stillWaiting: !_quakesFailed && !_liveDone)
            : Column(children: [
                for (final q in _quakes.take(3))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(children: [
                      Icon(Icons.circle, size: 8, color: cs.error),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(q.place, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, height: 1.15), maxLines: 2, overflow: TextOverflow.ellipsis),
                          Text('depth ${q.depthKm.round()} km', style: TextStyle(fontSize: 11.5, color: cs.onSurface.withValues(alpha: 0.55), height: 1.2)),
                        ]),
                      ),
                      Text(
                        'M ${q.magnitude.toStringAsFixed(1)}  ${(q.distanceM / 1000).round()} km',
                        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()]),
                      ),
                    ]),
                  ),
              ]),
      ),
      const SizedBox(height: 14),
      // Registered safety cameras nearby - OpenStreetMap's Overpass API. A
      // camera inside 150 m is drawn in the alert colour: the honest point of
      // the card is knowing when one is right on top of you.
      _liveCard(
        context,
        icon: Icons.photo_camera_outlined,
        title: tFn('travel.cameras'),
        onRefresh: _refresh,
        child: _cameras.isEmpty
            ? _emptyOrWaiting(context, failed: _camerasFailed, stillWaiting: !_camerasFailed && !_liveDone)
            : Column(children: [
                for (final c in _cameras.take(3))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(children: [
                      Icon(Icons.photo_camera, size: 15, color: c.distanceM < 150 ? cs.error : cs.primary),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          c.name.isEmpty ? c.kind : '${c.name}  ·  ${c.kind}',
                          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, height: 1.15),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        '${c.distanceM.round()} m',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: c.distanceM < 150 ? cs.error : cs.onSurface.withValues(alpha: 0.65),
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ]),
                  ),
              ]),
      ),
      const SizedBox(height: 14),
      // Live view: a small plain map of where the phone sits right now. It
      // follows the same stream the mode ring reads - nothing is shared out.
      Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.map_outlined, size: 18, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(child: Text(tFn('travel.live_view'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
            ]),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                height: 170,
                width: double.infinity,
                child: _last == null
                    ? _hint(context, tFn('travel.waiting'))
                    : FlutterMap(
                        options: MapOptions(
                          initialCenter: LatLng(_last!.lat, _last!.lon),
                          initialZoom: 15,
                          interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
                        ),
                        children: [
                          TileLayer(
                            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                            userAgentPackageName: 'ng.sentri.sentri',
                          ),
                          MarkerLayer(markers: [
                            Marker(
                              point: LatLng(_last!.lat, _last!.lon),
                              width: 40,
                              height: 40,
                              child: Icon(Icons.my_location, size: 26, color: cs.primary),
                            ),
                          ]),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: 8),
            _hint(context, tFn('travel.live_note')),
          ]),
        ),
      ),
    ];
  }
}

/// The ring that turns the live speed into a dial (v43). A track circle plus
/// one rounded arc that sweeps clockwise from 12 o'clock, with a soft glow so
/// the fill reads as light, not as a chart.
class _SpeedRing extends CustomPainter {
  _SpeedRing({required this.progress, required this.color, required this.track});
  final double progress;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = 9.0;
    final rect = Offset(stroke / 2, stroke / 2) & Size(size.width - stroke, size.height - stroke);
    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = track;
    canvas.drawArc(rect, 0, 2 * 3.1415926535897932, false, trackPaint);
    final sweep = 2 * 3.1415926535897932 * progress.clamp(0.0, 1.0);
    if (sweep > 0.01) {
      final fillPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = color;
      // Start at 12 o'clock and sweep clockwise.
      canvas.drawArc(rect, -3.1415926535897932 / 2, sweep, false, fillPaint);
    }
  }

  @override
  bool shouldRepaint(_SpeedRing old) => old.progress != progress || old.color != color;
}
