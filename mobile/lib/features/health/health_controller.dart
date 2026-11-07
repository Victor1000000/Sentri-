import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:health/health.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../../core/i18n/i18n.dart';
import '../../core/net/api.dart';
import '../../core/settings.dart';
import '../location/location.dart';
import '../push/push_service.dart';

/// One hospital around the person, from the free OpenStreetMap service.
class NearbyHospital {
  const NearbyHospital({required this.name, required this.km, this.phone});
  final String name;

  /// Straight-line distance in kilometres.
  final double km;

  /// The public phone line as saved on the map, or null when OSM has none yet.
  final String? phone;
}

/// The watchful heart of the Health tab:
///
///  * reads real heart-rate samples through Health Connect (the accurate source on the phone:
///    what a band, watch or the phone's own health app saved),
///  * learns the person's typical resting heart rate and warns when the latest reading climbs
///    far above it for more than a moment,
///  * if it happens again and again inside an hour, the emergency contacts are told once
///    (through the backend, exactly like a low-battery note),
///  * keeps hospitals near the person ready to show and call.
///
/// It never invents a number: with no source connected, it says so plainly.
class HealthController extends ChangeNotifier {
  HealthController({required this.api, required this.settings, required this.location, required this.i18n});
  final SentriApi api;
  final AppSettings settings;
  final LocationSource location;
  final I18n i18n;

  final _health = Health();

  /// null = not checked yet; true = Health Connect is on the phone; false = not installed.
  bool? connected;
  bool authorized = false;

  /// The most recent heart-rate reading, in beats per minute.
  int? bpm;
  DateTime? bpmAt;

  /// The resting heart rate the person's own records show, when enough data exists.
  int? baseline;

  List<NearbyHospital> hospitals = const [];
  bool hospitalsLoading = false;
  bool hospitalsFailed = false;

  Timer? _poll;
  DateTime? _historyAt;
  String? _lastWaterKey;
  DateTime? _hospitalsAt;

  // ---- anomaly bookkeeping -------------------------------------------------
  final _recent = <DateTime, double>{};
  DateTime? _lastLocalAlertAt;
  DateTime? _lastChronicAt;
  DateTime? _episodeWindowAt;
  int _episodes = 0;

  static const _pollEvery = Duration(minutes: 5);
  static const _nightStart = 0, _nightEnd = 6;
  static const _baselineRefetch = Duration(hours: 6);
  static const _localCooldown = Duration(minutes: 30);
  static const _chronicCooldown = Duration(hours: 6);
  static const _episodeWindow = Duration(minutes: 60);
  static const _hospitalsRefetch = Duration(minutes: 10);

  void start() {
    if (_poll != null) return;
    unawaited(_init());
    _poll = Timer.periodic(_pollEvery, (_) => unawaited(_pollOnce()));
    settings.addListener(_onSettings);
    _onSettings();
  }

  void _onSettings() {
    final key = '${settings.waterMinutes}|${i18n.code}';
    if (key == _lastWaterKey) {
      notifyListeners(); // the chip highlight follows the setting wherever it is changed
      return;
    }
    _lastWaterKey = key;
    unawaited(scheduleWaterReminder(
      settings.waterMinutes,
      i18n.t('health.water_title'),
      i18n.t('health.water_body'),
    ));
    notifyListeners();
  }

  Future<void> _init() async {
    try {
      await _health.configure();
      connected = await _health.isHealthConnectAvailable();
    } catch (_) {
      connected = false;
    }
    notifyListeners();
  }

  /// Asks the person to allow heart-rate reading. Called from the Health tab, so the request
  /// happens on purpose, on a screen that explains it.
  Future<void> authorize() async {
    if (connected != true) return;
    try {
      authorized = await _health.requestAuthorization([HealthDataType.HEART_RATE], permissions: [HealthDataAccess.READ]);
      if (authorized) await _health.requestHealthDataHistoryAuthorization();
    } catch (_) {
      authorized = false;
    }
    notifyListeners();
    if (authorized) {
      baseline = await _fetchBaseline();
      unawaited(_pollOnce());
      notifyListeners();
    }
  }

  Future<void> _pollOnce() async {
    if (connected != true || !authorized) return;
    final now = DateTime.now();
    try {
      final start = now.subtract(const Duration(minutes: 45));
      final pts = await _health.getHealthDataFromTypes(
        types: [HealthDataType.HEART_RATE],
        startTime: start,
        endTime: now,
      );
      double? bpmOf(HealthDataPoint p) {
        final x = p.value is NumericHealthValue ? (p.value as NumericHealthValue).numericValue : null;
        return x == null ? null : x.toDouble();
      }
      pts.sort((a, b) => b.dateTo.compareTo(a.dateTo));
      final latest = pts.isEmpty ? null : pts.first;
      final v = latest == null ? null : bpmOf(latest);
      if (v == null || v < 30 || v > 250) return;
      bpm = v.round();
      bpmAt = latest!.dateTo;
      _recent[latest.dateTo] = v;
      // Keep only the last ten minutes of samples.
      final cut = now.subtract(const Duration(minutes: 10));
      _recent.removeWhere((t, _) => t.isBefore(cut));
      _checkElevated();
      notifyListeners();

      // The typical resting rate: refetched every few hours, once we have readings.
      if (baseline == null || _historyAt == null || now.difference(_historyAt!) > _baselineRefetch) {
        final b = await _fetchBaseline();
        baseline = b ?? baseline;
        notifyListeners();
      }
    } catch (_) {
      // A failed read must never be shown as a made-up number; the honest state remains.
    }
  }

  /// Median of the past seven days' sleeping-hours readings (00:00-06:00 local), falling back
  /// to the median of all readings in the window. Needs the history permission to reach
  /// last week's data; without it we try anyway and keep whatever comes back.
  Future<int?> _fetchBaseline() async {
    final now = DateTime.now();
    try {
      final week = await _health.getHealthDataFromTypes(
        types: [HealthDataType.HEART_RATE],
        startTime: now.subtract(const Duration(days: 7)),
        endTime: now,
      );
      final vals = <double>[];
      final night = <double>[];
      for (final p in week) {
        final v = p.value is NumericHealthValue ? (p.value as NumericHealthValue).numericValue : null;
        if (v == null || v < 30 || v > 250) continue;
        final d = v.toDouble();
        vals.add(d);
        final h = p.dateTo.hour;
        if (h >= _nightStart && h < _nightEnd) night.add(d);
      }
      _historyAt = now;
      double median(List<double> xs) {
        xs.sort();
        final n = xs.length;
        if (n.isOdd || n == 1) return xs[(n - 1) ~/ 2];
        return (xs[n ~/ 2 - 1] + xs[n ~/ 2]) / 2;
      }
      final chosen = night.length >= 5 ? night : vals;
      if (chosen.length < 3) return null;
      final b = median(chosen).round();
      if (b < 30 || b > 110) return b.clamp(30, 110);
      return b;
    } catch (_) {
      return null;
    }
  }

  /// An abnormal climb = today's reading is far above the person's own resting rate AND
  /// absolutely high, and it happens on at least two samples within ten minutes. One spike
  /// gets a gentle note; repeated spikes inside an hour tell the emergency contacts once.
  void _checkElevated() {
    final now = DateTime.now();
    final base = baseline ?? 70.0;
    final threshold = (base + 30).clamp(100.0, 200.0);
    var samples = 0;
    for (final v in _recent.values) {
      if (v >= threshold) samples++;
    }
    if (samples < 2) return;

    // Episode window: counts repeated climbs inside an hour.
    if (_episodeWindowAt == null || now.difference(_episodeWindowAt!) > _episodeWindow) {
      _episodeWindowAt = now;
      _episodes = 0;
    }
    if (_lastLocalAlertAt != null && now.difference(_lastLocalAlertAt!) < _localCooldown) {
      _checkChronic(now);
      return;
    }
    _lastLocalAlertAt = now;
    _episodes++;
    _checkChronic(now);
    unawaited(showHealthNote(i18n.t('health.hr_alert_title'), i18n.t('health.hr_alert_body', {'n': '$bpm'})));
  }

  Future<void> _checkChronic(DateTime now) async {
    if (_episodes < 3) return;
    if (_lastChronicAt != null && now.difference(_lastChronicAt!) < _chronicCooldown) return;
    _lastChronicAt = now;
    _episodes = 0;
    // The last known position goes with the note so contacts can act on it.
    GeoFix? geo;
    try {
      geo = await location.fix(highAccuracy: true, timeout: const Duration(seconds: 8)) ?? await location.lastKnown();
    } catch (_) {}
    try {
      await api.healthAlert(geo);
    } catch (_) {
      // Offline: the note will go when the app is back online and the pattern repeats.
    }
  }

  /// Hospitals near the person, straight from the free OpenStreetMap service.
  /// Refreshed at most every ten minutes.
  Future<void> loadHospitals({bool force = false}) async {
    if (hospitalsLoading) return;
    final had = _hospitalsAt;
    if (!force && had != null && had.isAfter(DateTime.now().subtract(_hospitalsRefetch))) return;
    hospitalsLoading = true;
    notifyListeners();
    DateTime? at;
    try {
      final f = await location.preciseFix(timeout: const Duration(seconds: 15));
      final here = f == null ? null : LatLng(f.lat, f.lon);
      if (here == null) {
        hospitalsFailed = true;
      } else {
        at = DateTime.now();
        hospitals = await _fetchHospitals(here);
        hospitalsFailed = false;
      }
    } catch (_) {
      hospitalsFailed = true;
    }
    _hospitalsAt = at ?? DateTime.now();
    hospitalsLoading = false;
    notifyListeners();
  }

  Future<List<NearbyHospital>> _fetchHospitals(LatLng here) async {
    const radius = 15000.0;
    final q = '[out:json][timeout:25];('
        'node(around:\$radius,${here.latitude},${here.longitude})["amenity"~"^(hospital|clinic)\$"];'
        'way(around:\$radius,${here.latitude},${here.longitude})["amenity"~"^(hospital|clinic)\$"];'
        ');out center tags;';
    final res = await http.post(
      Uri.parse('https://overpass-api.de/api/interpreter'),
      body: {'data': q},
    ).timeout(const Duration(seconds: 40));
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final out = <NearbyHospital>[];
    final dist = const Distance();
    for (final el in (j['elements'] as List? ?? const [])) {
      if (el is! Map<String, dynamic>) continue;
      final center = el['center'] is Map ? el['center'] as Map<String, dynamic> : el;
      final la = center['lat'];
      final lo = center['lon'];
      if (la is! num || lo is! num) continue;
      final tags = (el['tags'] is Map ? el['tags'] as Map<String, dynamic> : const <String, dynamic>{}) as Map<String, dynamic>;
      final phone = (tags['phone'] ?? tags['contact:phone'] ?? tags['healthcare:phone']) as String?;
      final name = tags['name'] as String?;
      if ((name == null || name.isEmpty) && (phone == null || phone.isEmpty)) continue;
      out.add(NearbyHospital(
        name: (name == null || name.isEmpty) ? 'Hospital' : name,
        km: dist.as(LengthUnit.Kilometer, here, LatLng(la.toDouble(), lo.toDouble())),
        phone: (phone == null || phone.isEmpty) ? null : phone,
      ));
    }
    out.sort((a, b) => a.km.compareTo(b.km));
    return out.take(12).toList();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _poll = null;
    settings.removeListener(_onSettings);
    super.dispose();
  }
}
