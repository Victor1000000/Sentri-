import 'dart:async';
import 'dart:convert';

import 'package:camera/camera.dart' show CameraController;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:health/health.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../../core/i18n/i18n.dart';
import '../../core/net/api.dart';
import '../../core/settings.dart';
import '../location/location.dart';
import '../push/push_service.dart';
import 'heart_camera.dart';

/// One hospital, gym or stadium around the person, from the free OpenStreetMap
/// services (Overpass mirrors, Nominatim, Photon) plus the embedded verified
/// directories. Carries its position so tapping it can start a route on the map.
class NearbyPlace {
  const NearbyPlace({
    required this.name,
    required this.km,
    required this.lat,
    required this.lon,
    this.phone,
    this.city,
  });
  final String name;

  /// Straight-line distance in kilometres.
  final double km;
  final double lat;
  final double lon;

  /// The public phone line: verified from official sources in the embedded
  /// directories, or as saved on the map. Null when nobody published one yet.
  final String? phone;

  /// City/area label from the embedded directory, when it came from there.
  final String? city;

  /// A forgiving match key for de-duplicating the same place found by several
  /// sources: lowercase, letters and digits only.
  String get key {
    final sb = StringBuffer();
    for (final c in name.toLowerCase().runes) {
      final ch = String.fromCharCode(c);
      if ((c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x7a)) sb.write(ch);
    }
    return sb.toString();
  }

  bool similarNameTo(NearbyPlace o) {
    final a = key, b = o.key;
    if (a.isEmpty || b.isEmpty) return false;
    if (a == b) return true;
    final short = a.length < b.length ? a : b;
    final long = a.length < b.length ? b : a;
    return short.length >= 6 && (long.contains(short) || _withinEdits(short, long, 2));
  }

  static bool _withinEdits(String a, String b, int max) {
    if ((b.length - a.length).abs() > max) return false;
    var i = 0, j = 0, edits = 0;
    while (i < a.length && j < b.length) {
      if (a.codeUnitAt(i) == b.codeUnitAt(j)) {
        i++;
        j++;
        continue;
      }
      if (++edits > max) return false;
      if (a.length < b.length) {
        j++;
      } else if (a.length > b.length) {
        i++;
      } else {
        i++;
        j++;
      }
    }
    return true;
  }
}

/// Free mirrors of the OpenStreetMap query service. Instead of trying them one after
/// another (up to six slow timeouts stacked is what blanked the list before), all are
/// raced at once and merged when they answer.
const _overpassEndpoints = <String>[
  'https://overpass-api.de/api/interpreter',
  'https://overpass.kumi.systems/api/interpreter',
  'https://overpass.private.coffee/api/interpreter',
  'https://overpass.osm.ch/api/interpreter',
  'https://overpass.openstreetmap.ru/api/interpreter',
  'https://maps.mail.ru/osm/tools/overpass/api/interpreter',
];

/// The watchful heart of the Health tab:
///
///  * reads real heart-rate samples through Health Connect (the accurate source on the phone:
///    what a band, watch or the phone's own health app saved),
///  * learns the person's typical resting heart rate and warns when the latest reading climbs
///    far above it for more than a moment,
///  * if it happens again and again inside an hour, the emergency contacts are told once
///    (through the backend, exactly like a low-battery note),
///  * keeps hospitals AND gyms/stadiums near the person ready to show, call and route to.
///
/// It never invents a number: with no source connected, it says so plainly.
class HealthController extends ChangeNotifier with WidgetsBindingObserver {
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

  List<NearbyPlace> hospitals = const [];
  bool hospitalsLoading = false;
  bool hospitalsFailed = false;

  List<NearbyPlace> gyms = const [];
  bool gymsLoading = false;
  bool gymsFailed = false;

  /// How many automatic re-tries the last place failure has spawned (max
  /// [_hospMaxRetries]); reset to 0 on every success so a temporary hiccup never
  /// gives up permanently.
  int _placeRetries = 0;
  Timer? _placeRetryTimer;
  Future<void> Function()? _placeRetryAction;

  /// true when the map service answered fine but no location could be had - a different
  /// problem with a different advice than "service unreachable".
  bool hospitalsNoLocation = false;
  bool gymsNoLocation = false;

  /// The drink-water reminder's honest state, refreshed whenever the tab opens or the
  /// pace changes: off (no reminder chosen), ok (scheduled and allowed by the phone),
  /// noPermission (the phone blocks notifications) or notScheduled (the schedule did
  /// not land - battery savers et al).
  WaterStatus waterStatus = WaterStatus.off;

  // ---- the app's own pulse reading (camera on the fingertip, screen light) ----
  final HeartCamera _camera = HeartCamera();
  bool measuring = false;
  int measureLeft = 0;
  int? cameraBpm;
  bool measureFailed = false;
  bool noCamera = false;

  /// true when the last reading failed because the camera stream delivered no frames
  /// at all (dark screen, camera busy) - different advice than a weak pulse.
  bool measureNofeed = false;

  /// The active camera controller during a measurement - the screen shows its preview so
  /// frames keep flowing. Null when not measuring.
  CameraController? get cameraPreview => _camera.controller;

  Timer? _poll;
  DateTime? _historyAt;
  String? _lastWaterKey;
  DateTime? _hospitalsAt;
  DateTime? _gymsAt;

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
  static const _placesRefetch = Duration(minutes: 10);
  static const _hospMaxRetries = 2;
  static const _placeRetryDelay = Duration(seconds: 20);

  /// After the first map source answers, the others get this long to also finish;
  /// everything that arrives inside the grace window is merged into one list, so the
  /// result covers ALL the hospitals/gyms the sources know, not just the fastest one's.
  static const _mergeGrace = Duration(seconds: 8);

  void start() {
    if (_poll != null) return;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_init());
    _poll = Timer.periodic(_pollEvery, (_) => unawaited(_pollOnce()));
    settings.addListener(_onSettings);
    _onSettings();
  }

  /// Re-arms the water reminder and refreshes hospitals when this tab is opened.
  /// Both are cheap and idempotent; called from the Health screen's initState.
  Future<void> onHealthTabOpen() async {
    ensureWaterReminder();
    unawaited(refreshWaterStatus());
    if (hospitalsFailed || hospitalsNoLocation || hospitals.isEmpty) {
      unawaited(loadHospitals(force: hospitalsFailed || hospitalsNoLocation));
    }
    if (gymsFailed || gymsNoLocation || gyms.isEmpty) {
      unawaited(loadGyms(force: gymsFailed || gymsNoLocation));
    }
  }

  /// The drink-water reminder lives as a chain of one-shot alarms the app tops back
  /// up on every open (see push_service.scheduleWaterReminder). Re-running it here is
  /// what keeps the chain stocked - a healthy chain is left strictly alone, a purged
  /// one is refilled.
  void ensureWaterReminder() {
    unawaited(scheduleWaterReminder(
      settings.waterMinutes,
      i18n.t('health.water_title'),
      i18n.t('health.water_body'),
    ));
  }

  /// Reads back what actually happened to the reminder on this phone: is it really
  /// scheduled and allowed? The Health tab shows the honest answer to the person.
  Future<void> refreshWaterStatus() async {
    final st = await waterReminderStatus(settings.waterMinutes);
    if (st != waterStatus) {
      waterStatus = st;
      notifyListeners();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ensureWaterReminder();
    }
  }

  void _onSettings() {
    final key = '${settings.waterMinutes}|${i18n.code}';
    if (key == _lastWaterKey) {
      notifyListeners(); // the chip highlight follows the setting wherever it is changed
      return;
    }
    _lastWaterKey = key;
    ensureWaterReminder();
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

  /// One pulse reading taken by the app itself: fingertip over the front camera with the
  /// bright screen lighting it, about fifteen seconds, then the maths decides whether it
  /// can trust the numbers. No health app involved at any step.
  ///
  /// v39: the camera permission is asked for HERE, right before the take. A fresh
  /// install (or a reinstall) starts with no camera permission, and the camera plugin
  /// fails silently instead of asking - which looked like "the heart rate stopped
  /// working" after an update. Asking first means the person sees the system dialog,
  /// and a refusal gets its own clear note on the card.
  Future<void> measureWithCamera() async {
    if (measuring) return;
    measuring = true;
    measureFailed = false;
    measureNofeed = false;
    noCamera = false;
    cameraBpm = null;
    measureLeft = HeartCamera.secondsTarget;
    notifyListeners();
    try {
      final st = await Permission.camera.request();
      if (!st.isGranted) {
        measuring = false;
        measureLeft = 0;
        noCamera = true; // the card's "no camera" advice, which names the permission
        measureFailed = true;
        notifyListeners();
        return;
      }
    } catch (_) {
      // No permission plugin on this platform: fall through and let the camera try.
    }
    int? r;
    try {
      r = await _camera.measure(onTick: (s) {
        measureLeft = s;
        notifyListeners();
      });
    } catch (_) {
      r = null;
    }
    measuring = false;
    measureLeft = 0;
    noCamera = _camera.cameraMissing;
    if (r == null) {
      // Distinguish "no frames at all" (dark screen, camera busy) from "the reading was
      // not strong enough" - each gets its own honest advice.
      measureNofeed = _camera.frames == 0;
      measureFailed = true;
      notifyListeners();
      return;
    }
    cameraBpm = r;
    bpm = r;
    bpmAt = DateTime.now();
    unawaited(settings.addHeartTake(bpmAt!, r)); // the history the card shows
    notifyListeners();
  }

  /// Hospitals - and gyms/stadiums - near the person. Nine sources are raced at once:
  /// six Overpass mirrors, Nominatim (hospital query and a gym/general query) and
  /// Photon - deliberately different families, so one blocked service cannot blank
  /// the list. When the first source answers, the others get a short grace window;
  /// EVERYTHING that lands inside it is merged and de-duplicated, so the list covers
  /// all the places around, not just the fastest source's findings. Numbers come from
  /// the map where it has them, plus the embedded verified directory.
  ///
  /// Every step gets a short timeout (location per attempt, the race 45 s) so the
  /// whole load can never crawl for minutes before anything shows.
  Future<void> loadHospitals({bool force = false}) async {
    await _loadPlaces(gym: false, force: force);
  }

  Future<void> loadGyms({bool force = false}) async {
    await _loadPlaces(gym: true, force: force);
  }

  Future<void> _loadPlaces({required bool gym, bool force = false}) async {
    final loading = gym ? gymsLoading : hospitalsLoading;
    if (loading) return;
    final had = gym ? _gymsAt : _hospitalsAt;
    if (!force && had != null && had.isAfter(DateTime.now().subtract(_placesRefetch))) return;
    _setPlaceFlags(gym: gym, loading: true, failed: false, noLocation: false);
    try {
      // A precise fix first; if it is slow or refuses, a fast fix, then the last known
      // spot - a slightly rough area is still far better than nothing to show.
      GeoFix? f;
      try {
        f = await location.preciseFix(timeout: const Duration(seconds: 20));
      } catch (_) {}
      if (f == null) {
        try {
          f = await location.fix(highAccuracy: true, timeout: const Duration(seconds: 10));
        } catch (_) {}
      }
      if (f == null) {
        try {
          f = await location.lastKnown();
        } catch (_) {
          f = null;
        }
      }
      // The cached "last known spot" is only useful when it is fresh: after hours it
      // may describe a different city (an earlier trip), and then the whole nearby
      // list fills with hospitals from Lagos or Ibadan while the person sits in
      // Abeokuta. A stale fix is treated the same as no fix at all.
      if (f != null && DateTime.now().difference(f.at) > const Duration(minutes: 15)) f = null;
      if (f == null) {
        // Honest split: the map service may be fine - the problem is no location yet.
        _setPlaceFlags(gym: gym, loading: false, failed: false, noLocation: true, at: DateTime.now());
        return;
      }
      final here = LatLng(f.lat, f.lon);
      final results = await _racePlaces(gym: gym, here: here);
      if (results == null) {
        _setPlaceFlags(gym: gym, loading: false, failed: true);
        // Mobile networks trip far more often than the sources actually being down:
        // quietly try again a little later instead of just showing an error.
        _schedulePlaceRetry(gym: gym);
      } else {
        // Embedded verified directory first: real numbers researched from official
        // sources, added to the same list and de-duplicated against map results.
        final dir = await _loadDirectory(gym ? 'fitness_directory.json' : 'hospital_directory.json', here);
        final all = _nearOnly(_mergePlaces([results, dir], here));
        if (gym) {
          gyms = all;
          _gymsAt = DateTime.now();
          gymsFailed = false;
          gymsLoading = false;
        } else {
          hospitals = all;
          _hospitalsAt = DateTime.now();
          hospitalsFailed = false;
          hospitalsLoading = false;
        }
        _placeRetries = 0;
      }
    } catch (_) {
      // Nothing may leave this spinner stuck: any surprise ends as a refreshable error.
      _setPlaceFlags(gym: gym, loading: false, failed: true);
    } finally {
      _setPlaceFlags(gym: gym, loading: gym ? gymsLoading : hospitalsLoading, failed: null);
      notifyListeners();
    }
  }

  void _setPlaceFlags({required bool gym, bool? loading, bool? failed, bool? noLocation, DateTime? at}) {
    if (gym) {
      if (loading != null) gymsLoading = loading;
      if (failed != null) gymsFailed = failed;
      if (noLocation != null) gymsNoLocation = noLocation;
      if (at != null) _gymsAt = at;
    } else {
      if (loading != null) hospitalsLoading = loading;
      if (failed != null) hospitalsFailed = failed;
      if (noLocation != null) hospitalsNoLocation = noLocation;
      if (at != null) _hospitalsAt = at;
    }
    notifyListeners();
  }

  /// Races all sources for one kind of place, waits out the merge grace after the
  /// first answer, and returns the merged list. Null = no source was reachable.
  Future<List<NearbyPlace>?> _racePlaces({required bool gym, required LatLng here}) async {
    final racers = <Future<List<NearbyPlace>?> Function()>[
      for (final url in _overpassEndpoints) () => _overpassQuery(url, here, gym),
      () => _nominatimQuery(here, gym),
      () => _photonQuery(here, gym),
    ];
    final got = <List<NearbyPlace>>[];
    final done = Completer<List<NearbyPlace>?>();
    var pending = racers.length;
    var answeredEmpty = false;
    Timer? grace;

    void settle(List<NearbyPlace>? result) {
      grace?.cancel();
      grace = null;
      if (!done.isCompleted) done.complete(result);
    }

    Future<void> race(Future<List<NearbyPlace>?> Function() q) async {
      try {
        final r = await q().timeout(const Duration(seconds: 45));
        if (r != null && r.isNotEmpty) {
          got.add(r);
          // First answer: give the other sources a short window to also finish,
          // then merge everything - coverage beats pure speed, once something shows.
          if (got.length == 1) {
            grace = Timer(_mergeGrace, () => settle(_mergePlaces(got, here)));
          }
        } else if (r != null) {
          // A service answered properly but found nothing nearby: honest "none"
          // if every source agrees there is nothing.
          answeredEmpty = true;
        }
      } catch (_) {
        // this source is out; the others keep racing
      } finally {
        pending--;
        if (pending <= 0) {
          if (got.isEmpty) {
            settle(answeredEmpty ? const <NearbyPlace>[] : null);
          } else {
            settle(_mergePlaces(got, here));
          }
        }
      }
    }

    for (final q in racers) {
      unawaited(race(q));
    }
    final res = await done.future;
    return res;
  }

  /// One list out of many: nearest first, same place found by several sources kept
  /// once (same forgiving name, or same phone number, or within ~100 m of each other).
  List<NearbyPlace> _mergePlaces(List<List<NearbyPlace>> lists, LatLng here) {
    final all = <NearbyPlace>[];
    for (final l in lists) {
      for (final p in l) {
        all.add(p);
      }
    }
    all.sort((a, b) => a.km.compareTo(b.km));
    final out = <NearbyPlace>[];
    for (final p in all) {
      NearbyPlace twin = p;
      var merged = false;
      for (var i = 0; i < out.length; i++) {
        final q = out[i];
        if (_samePlace(p, q)) {
          // Keep the richer twin: fuller name, and a phone when only one has it.
          twin = NearbyPlace(
            name: q.name.length >= p.name.length ? q.name : p.name,
            km: q.km <= p.km ? q.km : p.km,
            lat: q.lat,
            lon: q.lon,
            phone: q.phone ?? p.phone,
            city: q.city ?? p.city,
          );
          out[i] = twin;
          merged = true;
          break;
        }
      }
      if (!merged) out.add(p);
    }
    return out.take(40).toList();
  }

  /// The final gate for what may be shown as "near you": only places within the
  /// search radius, nearest first, at most 20 of them. Even when a source is
  /// generous with its answer, nothing from another city can slip onto the list.
  List<NearbyPlace> _nearOnly(List<NearbyPlace> list) {
    final out = <NearbyPlace>[];
    for (final p in list) {
      if (p.km <= _placesRadiusKm) out.add(p);
    }
    out.sort((a, b) => a.km.compareTo(b.km));
    return out.take(20).toList();
  }

  /// Same place found twice? Same forgiving name (or nearly), or the last nine
  /// digits of the phone, or within ~100 m of each other with a similar name.
  bool _samePlace(NearbyPlace a, NearbyPlace b) {
    if (a.phone != null && b.phone != null) {
      final pa = a.phone!.replaceAll(RegExp(r'[^0-9+]'), '');
      final pb = b.phone!.replaceAll(RegExp(r'[^0-9+]'), '');
      final na = pa.length > 9 ? pa.substring(pa.length - 9) : pa;
      final nb = pb.length > 9 ? pb.substring(pb.length - 9) : pb;
      if (pa.length >= 7 && na == nb) return true;
    }
    if (a.similarNameTo(b)) return true;
    final d = const Distance().as(LengthUnit.Kilometer, LatLng(a.lat, a.lon), LatLng(b.lat, b.lon));
    return d < 0.1 && a.similarNameTo(b);
  }

  /// The embedded verified directories (researched from official hospital and gym
  /// sources): name, position and public phone for major places, added to the map
  /// results. Entries further than the search area are skipped.
  Future<List<NearbyPlace>> _loadDirectory(String asset, LatLng here) async {
    final out = <NearbyPlace>[];
    try {
      final text = await rootBundle.loadString('assets/directory/$asset');
      final j = jsonDecode(text);
      if (j is! List) return out;
      final dist = const Distance();
      for (final el in j) {
        if (el is! Map<String, dynamic>) continue;
        final name = el['name'] as String?;
        final lat = (el['lat'] as num?)?.toDouble();
        final lon = (el['lon'] as num?)?.toDouble();
        if (name == null || lat == null || lon == null) continue;
        final km = dist.as(LengthUnit.Kilometer, here, LatLng(lat, lon));
        if (km > _placesRadiusKm) continue;
        final ph = (el['phone'] as String?) ?? '';
        out.add(NearbyPlace(
          name: name,
          km: km,
          lat: lat,
          lon: lon,
          phone: ph.isEmpty ? null : ph,
          city: el['city'] as String?,
        ));
      }
    } catch (_) {
      // A missing or broken directory must never break the map list.
    }
    return out;
  }

  /// When the map service could not be reached at all, quietly try again a bit later -
  /// a busy source or a flaky mobile link is much more common than genuinely no data.
  void _schedulePlaceRetry({required bool gym}) {
    if (_placeRetries >= _hospMaxRetries) return;
    _placeRetries++;
    _placeRetryTimer?.cancel();
    _placeRetryAction = () => _loadPlaces(gym: gym, force: true);
    _placeRetryTimer = Timer(_placeRetryDelay, () {
      _placeRetryTimer = null;
      final a = _placeRetryAction;
      _placeRetryAction = null;
      if (a != null) unawaited(a());
    });
  }

  /// One Overpass mirror; returns null when that mirror answers badly (bad code, timeout).
  Future<List<NearbyPlace>?> _overpassQuery(String url, LatLng here, [bool gym = false]) async {
    final radius = gym ? 20000.0 : _placesRadiusM;
    // Gyms also hide under shop=fitness and leisure=sports_hall in the map data; the
    // extra selectors lift the number found in towns where little else is tagged.
    final sel = gym
        ? '(leisure~"^(fitness_centre|sports_centre|stadium|sports_hall)\$" || shop="fitness")'
        : '"amenity"~"^(hospital|clinic)\$"';
    final q = '[out:json][timeout:20];('
        'node(around:\$radius,${here.latitude},${here.longitude})[$sel];'
        'way(around:\$radius,${here.latitude},${here.longitude})[$sel];'
        ');out center tags 250;';
    Future<List<NearbyPlace>?> read(http.Response res) async {
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return null;
      try {
        final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        return _placesFromOverpass(j, here);
      } catch (_) {
        return null;
      }
    }
    try {
      final res = await http
          .post(
            Uri.parse(url),
            headers: const {'User-Agent': _placesUa},
            body: {'data': q},
          )
          .timeout(const Duration(seconds: 40));
      final got = await read(res);
      if (got != null) return got;
      if (res.statusCode >= 400 && res.statusCode < 500) {
        return _overpassGet(url, q, here);
      }
      return null;
    } catch (_) {
      return _overpassGet(url, q, here);
    }
  }

  /// Some mirrors refuse the form-posted query on mobile networks but accept the same
  /// query as a plain GET link; worth one more exact attempt before giving up.
  Future<List<NearbyPlace>?> _overpassGet(String url, String q, LatLng here) async {
    try {
      final res = await http
          .get(
            Uri.parse('$url?data=${Uri.encodeQueryComponent(q)}'),
            headers: const {'User-Agent': _placesUa},
          )
          .timeout(const Duration(seconds: 40));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return null;
      final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      return _placesFromOverpass(j, here);
    } catch (_) {
      return null;
    }
  }

  static const _placesUa = 'SentriApp/1.0 (health tab; hospitals and gyms near you)';

  /// The only meaning of "near you" in this app: 15 km around where the person
  /// actually is. Nothing outside it may reach the list, from any source.
  static const double _placesRadiusKm = 15.0;
  static const double _placesRadiusM = _placesRadiusKm * 1000;

  /// Nominatim (the OpenStreetMap search service, hosted separately from Overpass). It
  /// often answers when the Overpass mirrors are unreachable, and its "extratags" carry
  /// the saved phone numbers. Bounded to a box around the person.
  Future<List<NearbyPlace>?> _nominatimQuery(LatLng here, [bool gym = false]) async {
    const spanLon = 0.15; // roughly 16 km across at Nigerian latitudes
    const spanLat = 0.12;
    final vb = '${(here.longitude - spanLon).toStringAsFixed(4)},'
        '${(here.latitude - spanLat).toStringAsFixed(4)},'
        '${(here.longitude + spanLon).toStringAsFixed(4)},'
        '${(here.latitude + spanLat).toStringAsFixed(4)}';
    final uri = Uri.parse('https://nominatim.openstreetmap.org/search').replace(queryParameters: {
      'format': 'jsonv2',
      'q': gym ? 'gym' : 'hospital',
      'viewbox': vb,
      'bounded': '1',
      'limit': '50',
      'extratags': '1',
    });
    try {
      final res = await http.get(uri, headers: {'User-Agent': _placesUa}).timeout(const Duration(seconds: 40));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return null;
      final j = jsonDecode(utf8.decode(res.bodyBytes));
      if (j is! List) return null;
      final out = <NearbyPlace>[];
      final dist = const Distance();
      for (final el in j) {
        if (el is! Map<String, dynamic>) continue;
        final cat = el['category'];
        final typ = el['type'];
        final okType = gym
            ? (cat == 'leisure' && (typ == 'fitness_centre' || typ == 'sports_centre' || typ == 'stadium'))
            : (cat == 'amenity' && (typ == 'hospital' || typ == 'clinic'));
        if (!okType) continue;
        final la = double.tryParse('${el['lat']}');
        final lo = el['lon'] is num ? (el['lon'] as num).toDouble() : double.tryParse('${el['lon']}');
        if (la == null || lo == null) continue;
        final extra = el['extratags'] is Map<String, dynamic> ? el['extratags'] as Map<String, dynamic> : const <String, dynamic>{};
        final phone = (extra['phone'] ?? extra['contact:phone']) as String?;
        var name = el['name'] as String?;
        final display = el['display_name'] as String?;
        if (name == null || name.isEmpty) {
          // No own name saved: use the first line of the address so the row is not blank.
          name = (display != null && display.isNotEmpty) ? display.split(',').first.trim() : (gym ? 'Gym' : 'Hospital');
        }
        out.add(NearbyPlace(
          name: name,
          km: dist.as(LengthUnit.Kilometer, here, LatLng(la, lo)),
          lat: la,
          lon: lo,
          phone: (phone == null || phone.isEmpty) ? null : phone,
        ));
      }
      out.sort((a, b) => a.km.compareTo(b.km));
      return out.take(40).toList();
    } catch (_) {
      return null;
    }
  }

  /// Photon (komoot's search service, on entirely different infrastructure again). A
  /// last resort that at least fills the list with names and distances, with phone
  /// numbers when the map data has them.
  Future<List<NearbyPlace>?> _photonQuery(LatLng here, [bool gym = false]) async {
    final qs = gym
        ? 'q=gym&lat=${here.latitude.toStringAsFixed(5)}&lon=${here.longitude.toStringAsFixed(5)}'
            '&limit=50&osm_tag=leisure%3Afitness_centre&osm_tag=leisure%3Asports_centre&osm_tag=leisure%3Astadium'
        : 'q=hospital&lat=${here.latitude.toStringAsFixed(5)}&lon=${here.longitude.toStringAsFixed(5)}'
            '&limit=50&osm_tag=amenity%3Ahospital&osm_tag=amenity%3Aclinic';
    final uri = Uri.parse('https://photon.komoot.io/api/?$qs');
    try {
      final res = await http.get(uri, headers: {'User-Agent': _placesUa}).timeout(const Duration(seconds: 40));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return null;
      final j = jsonDecode(utf8.decode(res.bodyBytes));
      final features = (j is Map<String, dynamic> ? j['features'] : null) as List?;
      if (features == null) return null;
      final out = <NearbyPlace>[];
      final dist = const Distance();
      final wantKey = gym ? 'leisure' : 'amenity';
      for (final f in features) {
        if (f is! Map<String, dynamic>) continue;
        final props = f['properties'] is Map<String, dynamic> ? f['properties'] as Map<String, dynamic> : const <String, dynamic>{};
        if (props['osm_key'] != wantKey) continue;
        final val = '${props['osm_value']}';
        final okVal = gym
            ? (val == 'fitness_centre' || val == 'sports_centre' || val == 'stadium')
            : (val == 'hospital' || val == 'clinic');
        if (!okVal) continue;
        final geometry = f['geometry'] is Map<String, dynamic> ? f['geometry'] as Map<String, dynamic> : null;
        final coords = (geometry?['coordinates'] ?? const []) as List;
        if (coords.length < 2) continue;
        final lo = coords[0] is num ? (coords[0] as num).toDouble() : double.tryParse('${coords[0]}');
        final la = coords[1] is num ? (coords[1] as num).toDouble() : double.tryParse('${coords[1]}');
        if (la == null || lo == null) continue;
        final name = (props['name'] as String?) ?? (gym ? 'Gym' : 'Hospital');
        out.add(NearbyPlace(
          name: name,
          km: dist.as(LengthUnit.Kilometer, here, LatLng(la, lo)),
          lat: la,
          lon: lo,
          phone: null,
        ));
      }
      out.sort((a, b) => a.km.compareTo(b.km));
      return out.take(40).toList();
    } catch (_) {
      return null;
    }
  }

  Future<List<NearbyPlace>> _placesFromOverpass(Map<String, dynamic> j, LatLng here) async {
    final out = <NearbyPlace>[];
    final dist = const Distance();
    for (final el in (j['elements'] as List? ?? const [])) {
      if (el is! Map<String, dynamic>) continue;
      final center = el['center'] is Map ? el['center'] as Map<String, dynamic> : el;
      final la = center['lat'];
      final lo = center['lon'];
      if (la is! num || lo is! num) continue;
      final tags = (el['tags'] is Map ? el['tags'] as Map<String, dynamic> : const <String, dynamic>{}) as Map<String, dynamic>;
      final phone = (tags['phone'] ?? tags['contact:phone'] ?? tags['contact:mobile'] ?? tags['healthcare:phone']) as String?;
      final name = tags['name'] as String?;
      if ((name == null || name.isEmpty) && (phone == null || phone.isEmpty)) continue;
      out.add(NearbyPlace(
        name: (name == null || name.isEmpty) ? 'Hospital' : name,
        km: dist.as(LengthUnit.Kilometer, here, LatLng(la.toDouble(), lo.toDouble())),
        lat: la.toDouble(),
        lon: lo.toDouble(),
        phone: (phone == null || phone.isEmpty) ? null : phone,
      ));
    }
    out.sort((a, b) => a.km.compareTo(b.km));
    return out.take(40).toList();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _poll = null;
    _placeRetryTimer?.cancel();
    _placeRetryTimer = null;
    settings.removeListener(_onSettings);
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {}
    super.dispose();
  }
}
