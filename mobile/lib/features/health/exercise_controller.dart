import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';
import 'package:pedometer/pedometer.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/storage/key_value_store.dart';
import '../location/location.dart';
import 'awards.dart';

/// One saved session: what kind, when it started, how long it took, how far it
/// went, how many steps (walk/run only), and the line drawn on the map. The path
/// is stored trimmed so the history stays small on the phone.
class WorkoutRecord {
  const WorkoutRecord({
    required this.mode,
    required this.start,
    required this.seconds,
    required this.km,
    required this.steps,
    required this.path,
  });
  final String mode;
  final DateTime start;
  final int seconds;
  final double km;
  final int steps;
  final List<LatLng> path;

  Map<String, dynamic> toJson() => {
        'm': mode,
        't': start.toIso8601String(),
        's': seconds,
        'k': double.parse(km.toStringAsFixed(3)),
        'p': steps,
        'r': [for (final pt in path) [pt.latitude.toStringAsFixed(5), pt.longitude.toStringAsFixed(5)]],
      };

  static WorkoutRecord? fromJson(Map<String, dynamic> j) {
    final m = switch (j['m']) { 'walk' => 'walk', 'run' => 'run', 'bike' => 'bike', _ => null };
    final t = DateTime.tryParse('${j['t'] ?? ''}');
    final s = j['s'] is num ? (j['s'] as num).toInt() : null;
    final k = j['k'] is num ? (j['k'] as num).toDouble() : null;
    final p = j['p'] is num ? (j['p'] as num).toInt() : null;
    final r = j['r'] is List ? j['r'] as List : null;
    if (m == null || t == null || s == null || k == null || p == null) return null;
    final pts = <LatLng>[];
    if (r != null) {
      for (final el in r) {
        if (el is List && el.length >= 2) {
          final la = double.tryParse('${el[0]}');
          final lo = double.tryParse('${el[1]}');
          if (la != null && lo != null) pts.add(LatLng(la, lo));
        }
      }
    }
    return WorkoutRecord(mode: m, start: t, seconds: s, km: k, steps: p, path: pts);
  }
}

/// How the person moved: a walk or a run counts steps on the phone's step
/// sensor; a ride measures distance from GPS only (a bike has no steps).
enum ExerciseMode { walk, run, bike }

/// The exercise engine: live tracking of a walk, run or bike session on the
/// phone's real sensors - the hardware step counter for steps (the same source
/// the phone's own health app trusts), GPS fixes fused into a distance and the
/// route line, with rough fixes and drifting jumps filtered out so phantom
/// metres never creep in. Every meaningful session is saved to the history, and
/// awards (milestones, broken records) are evaluated against the whole history.
class ExerciseController extends ChangeNotifier {
  ExerciseController({required KeyValueStore store, required LocationSource location, required this.awards})
      : _store = store,
        _location = location;

  final KeyValueStore _store;
  final LocationSource _location;
  final AwardStore awards;

  static const _historyKey = 'exercise.history.v1';
  static const _maxHistory = 60;
  static const _maxPathPoints = 300;
  static const _tick = Duration(seconds: 5);

  ExerciseMode mode = ExerciseMode.walk;
  bool active = false;

  int seconds = 0;
  double km = 0;
  int steps = 0;
  List<LatLng> path = const [];

  List<WorkoutRecord> history = const [];
  int get sessions => history.length;
  double get totalKm => history.fold(0.0, (a, r) => a + r.km);
  double get bestKm => history.fold(0.0, (a, r) => r.km > a ? r.km : a);
  int get bestSteps => history.fold(0, (a, r) => r.steps > a ? r.steps : a);

  DateTime? _startedAt;
  Timer? _tickTimer;
  StreamSubscription<StepCount>? _stepSub;
  int _stepBaseline = -1;
  double? _lastFixLat;
  double? _lastFixLon;
  bool _busy = false;
  final _dist = const Distance();

  /// The plausible kilometres for one 5-second tick per mode: even jogging hard
  /// cannot cover more than ~55 m in that time, and a bike far less than 150 m.
  /// Anything longer is a GPS jump (tunnel, tower guess) and its distance is
  /// thrown away instead of added, so the count stays honest.
  double get _maxTickKm => switch (mode) {
        ExerciseMode.walk => 0.05,
        ExerciseMode.run => 0.08,
        ExerciseMode.bike => 0.15,
      };

  Future<void> load() async {
    try {
      final raw = await _store.read(_historyKey);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw);
        if (list is List) {
          final out = <WorkoutRecord>[];
          for (final el in list) {
            if (el is! Map<String, dynamic>) continue;
            final r = WorkoutRecord.fromJson(el);
            if (r != null) out.add(r);
          }
          history = out;
        }
      }
    } catch (_) {
      history = const [];
    }
    notifyListeners();
  }

  /// Starts a session. Returns false when the phone refused (no step-sensor
  /// permission for walk/run), so the screen can say so and stop.
  Future<bool> start(ExerciseMode m) async {
    if (active) return false;
    if (m != ExerciseMode.bike) {
      try {
        final st = await Permission.activityRecognition.request();
        if (st.isDenied || st.isPermanentlyDenied) return false;
      } catch (_) {
        // Older phones have no such permission: the sensor still works.
      }
    }
    mode = m;
    active = true;
    seconds = 0;
    km = 0;
    steps = 0;
    path = const [];
    _startedAt = DateTime.now();
    _stepBaseline = -1;
    _lastFixLat = null;
    _lastFixLon = null;
    notifyListeners();
    _listenSteps(m);
    _tickTimer?.cancel();
    _tickTimer = Timer.periodic(_tick, (_) => unawaited(_onTick()));
    unawaited(_onTick()); // the first fix right away
    return true;
  }

  /// Steps come from the phone's hardware step counter. The stream reports the
  /// number of steps since the phone booted, so the first reading of the session
  /// is the zero point and the difference is the session's own steps.
  void _listenSteps(ExerciseMode m) {
    if (m == ExerciseMode.bike) return;
    try {
      _stepSub = Pedometer.stepCountStream.listen((e) {
        if (!active) return;
        if (_stepBaseline < 0) {
          _stepBaseline = e.steps;
          return;
        }
        final d = e.steps - _stepBaseline;
        if (d < 0) {
          // The counter restarted mid-session (rare): re-baseline and go on.
          _stepBaseline = e.steps;
          return;
        }
        if (d != steps) {
          steps = d;
          notifyListeners();
        }
      }, onError: (Object _) {
        // No sensor answer: steps stay at zero honestly, distance keeps counting.
      });
    } catch (_) {
      // No step sensor on this phone: distance still works.
    }
  }

  /// One tick: five more seconds on the clock, one fresh fix, fused in honestly.
  Future<void> _onTick() async {
    if (!active || _busy) return;
    _busy = true;
    try {
      final base = _startedAt;
      if (base != null) {
        final s = DateTime.now().difference(base).inSeconds;
        if (s != seconds) {
          seconds = s;
          notifyListeners();
        }
      }
      GeoFix? f;
      try {
        f = await _location.fix(highAccuracy: true, timeout: const Duration(seconds: 5));
      } catch (_) {}
      if (f == null) return;
      // Only real GPS-grade positions are trusted for distance: a tower/Wi-Fi
      // guess can sit hundreds of metres off and would corrupt the count.
      if (!usableForDistance(f, limitM: 35)) return;
      final lat = _lastFixLat;
      final lon = _lastFixLon;
      final here = LatLng(f.lat, f.lon);
      if (lat == null || lon == null) {
        _lastFixLat = f.lat;
        _lastFixLon = f.lon;
        notifyListeners();
        return;
      }
      final movedKm = _dist.as(LengthUnit.Kilometer, LatLng(lat, lon), here);
      if (movedKm <= _maxTickKm) {
        km += movedKm;
        _maybeAppendPoint(here, movedKm);
      }
      _lastFixLat = f.lat;
      _lastFixLon = f.lon;
      notifyListeners();
    } finally {
      _busy = false;
    }
  }

  /// Joins a point onto the route line, but only when the person really moved
  /// (over ~8 m) - standing still would pile dots on one house.
  void _maybeAppendPoint(LatLng pt, double movedKm) {
    if (movedKm < 0.005) return;
    final list = [...path];
    if (list.isNotEmpty && _dist.as(LengthUnit.Meter, list.last, pt) < 8) return;
    list.add(pt);
    if (list.length > _maxPathPoints) {
      // Thin the line to half its points but always keep the very start and end.
      final halved = <LatLng>[];
      for (var i = 0; i < list.length; i += 2) {
        halved.add(list[i]);
      }
      if (halved.last != list.last) halved.add(list.last);
      path = halved;
      return;
    }
    path = list;
  }

  /// Ends the session. When [keepRecord] is true and the session counts (a full
  /// minute or at least 200 m), it joins the history and every award kind it
  /// earns is minted; returns the NEWLY earned kinds (empty when nothing new).
  /// Records are judged against the history BEFORE the session joins it.
  Future<List<AwardKind>> stop({required bool keepRecord}) async {
    _tickTimer?.cancel();
    _tickTimer = null;
    unawaited(_stepSub?.cancel());
    _stepSub = null;
    final wasActive = active;
    final dur = seconds;
    final distanceKm = km;
    final sessionSteps = mode == ExerciseMode.bike ? 0 : steps;
    active = false;

    var earned = const <AwardKind>[];
    if (wasActive && keepRecord && (dur >= 60 || distanceKm >= 0.2)) {
      final prevBestKm = bestKm;
      final prevBestSteps = bestSteps;
      final wasFirst = history.isEmpty;
      final rec = WorkoutRecord(
        mode: switch (mode) { ExerciseMode.walk => 'walk', ExerciseMode.run => 'run', ExerciseMode.bike => 'bike' },
        start: _startedAt ?? DateTime.now(),
        seconds: dur,
        km: distanceKm,
        steps: sessionSteps,
        path: path,
      );
      history = [rec, ...history];
      if (history.length > _maxHistory) history = history.sublist(0, _maxHistory);
      await _saveHistory();
      final kinds = <AwardKind>[];
      if (wasFirst) kinds.add(AwardKind.first);
      final total = totalKm;
      if (total >= 5) kinds.add(AwardKind.km5);
      if (total >= 10) kinds.add(AwardKind.km10);
      if (total >= 21) kinds.add(AwardKind.km21);
      if (sessionSteps >= 10000) kinds.add(AwardKind.steps10k);
      if (distanceKm > 0.5 && distanceKm > prevBestKm) kinds.add(AwardKind.recordKm);
      if (sessionSteps >= 2000 && sessionSteps > prevBestSteps) kinds.add(AwardKind.recordSteps);
      if (history.length >= 5) kinds.add(AwardKind.sessions5);
      earned = await awards.earnAll(kinds);
    }
    notifyListeners();
    return earned;
  }

  Future<void> _saveHistory() async {
    try {
      await _store.write(_historyKey, jsonEncode([for (final r in history) r.toJson()]));
    } catch (_) {
      // Full storage must never scrape a workout off the screen; the next save tries again.
    }
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    unawaited(_stepSub?.cancel());
    super.dispose();
  }
}
