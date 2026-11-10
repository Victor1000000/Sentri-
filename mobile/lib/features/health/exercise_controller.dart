import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';
import 'package:pedometer/pedometer.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/storage/key_value_store.dart';
import '../../core/net/api.dart';
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

  /// How often the FALLBACK asks for a fresh GPS fix. The session's first
  /// choice is the device's own position stream ([LocationSource.positions]),
  /// which reports fresh readings as the person moves; some sources cannot
  /// stream (and a permission service can fail), so the fallback keeps the
  /// old ask-one-fix-on-a-timer behaviour, a bit more forgiving than before.
  /// The clock below keeps the visible seconds moving on their own.
  static const _tick = Duration(seconds: 5);

  /// The session clock must tick every single second - "tick tock" - instead of
  /// jumping in fives with the GPS cadence. A separate one-second timer only
  /// updates the seconds shown; distance and steps come from the sensors.
  static const _clockTick = Duration(seconds: 1);

  ExerciseMode mode = ExerciseMode.walk;
  bool active = false;

  int seconds = 0;
  double km = 0;
  int steps = 0;
  List<LatLng> path = const [];

  /// The most recent fix of the running session (rough ones included): the
  /// workout screen puts the camera on it at once, before the route line exists.
  GeoFix? lastFix;

  List<WorkoutRecord> history = const [];
  int get sessions => history.length;
  double get totalKm => history.fold(0.0, (a, r) => a + r.km);
  double get bestKm => history.fold(0.0, (a, r) => r.km > a ? r.km : a);
  int get bestSteps => history.fold(0, (a, r) => r.steps > a ? r.steps : a);

  DateTime? _startedAt;
  Timer? _clockTimer;
  Timer? _tickTimer; // only the fallback when the device cannot stream
  StreamSubscription<GeoFix>? _posSub;
  StreamSubscription<StepCount>? _stepSub;
  int _stepBaseline = -1;
  LatLng? _lastAccepted; // last fix trusted for the distance count
  DateTime? _lastAcceptedAt;
  double? _lastAcceptedAcc;
  final _dist = const Distance();

  /// A fix worse than this is a tower/Wi-Fi guess or heavy drift: it moves the
  /// camera dot on the map but is never trusted for the distance count. The
  /// movement noise check below keeps the honest sum even in between.
  static const _maxAccuracyM = 60.0;

  /// How fast each mode can plausibly move, metres per second, plus a few
  /// metres of slack: a walk cannot outrun 2.5 m/s, a run fits in 7, a bike
  /// in 20. A jump bigger than the limit over the time since the last trusted
  /// fix is a GPS rock (tunnel, tower guess) and is thrown away, NOT added.
  double get _maxSpeed => switch (mode) {
        ExerciseMode.walk => 2.5,
        ExerciseMode.run => 7.0,
        ExerciseMode.bike => 20.0,
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
    lastFix = null;
    _startedAt = DateTime.now();
    _stepBaseline = -1;
    _lastAccepted = null;
    _lastAcceptedAt = null;
    _lastAcceptedAcc = null;
    notifyListeners();
    _listenSteps(m);
    _clockTimer?.cancel();
    _clockTimer = Timer.periodic(_clockTick, (_) => _updateSeconds());
    unawaited(_track());
    return true;
  }

  /// Follows the person while the session runs: the device's own position
  /// stream when it can (every fresh reading as they move), one fix per tick
  /// otherwise. The camera centres on the last known spot right away.
  Future<void> _track() async {
    // An instant centre for the map, before the first streamed reading: the
    // OS's cached position costs nothing.
    try {
      final f = await _location.lastKnown();
      if (f != null && active && lastFix == null) {
        lastFix = f;
        notifyListeners();
      }
    } catch (_) {}
    try {
      _posSub = _location.positions(distanceFilterM: 4).listen(_onPosition, onDone: () {
        if (active) _startFallback();
      }, onError: (Object _) {
        if (active) _startFallback();
      });
      // If the source cannot stream at all, go straight to polling.
      if (_posSub == null) _startFallback();
    } on UnsupportedError {
      _startFallback();
    } catch (_) {
      _startFallback();
    }
  }

  /// Fallback tracking: one fresh fix every [_tick]. Used when the device
  /// cannot stream (or the stream died): same honest counting, slower cadence.
  void _startFallback() {
    if (_tickTimer != null || !active) return;
    _tickTimer = Timer.periodic(_tick, (_) => unawaited(_pollFix()));
    unawaited(_pollFix());
  }

  Future<void> _pollFix() async {
    if (!active) return;
    GeoFix? f;
    try {
      f = await _location.fix(highAccuracy: true, timeout: const Duration(seconds: 5));
    } catch (_) {}
    if (f != null) _onPosition(f);
  }

  /// Re-reads the clock from the start time each second, so the big digits move
  /// tick, tock - even while a GPS fix is slow.
  void _updateSeconds() {
    final base = _startedAt;
    if (!active || base == null) return;
    final s = DateTime.now().difference(base).inSeconds;
    if (s != seconds) {
      seconds = s;
      notifyListeners();
    }
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

  /// One fresh reading from the phone, streamed or polled. The map camera
  /// follows whatever comes in; the distance count only trusts readings that
  /// pass three honest checks - good accuracy, no impossible jump since the
  /// last trusted reading, and real movement beyond the noise floor.
  void _onPosition(GeoFix f) {
    if (!active) return;
    // The camera target is the freshest fix, whatever its quality.
    lastFix = f;
    // A tower/Wi-Fi guess can sit hundreds of metres off and would corrupt
    // the count: a fix this rough still steers the camera but is not trusted.
    final acc = f.accuracyM ?? double.infinity;
    if (acc > _maxAccuracyM) {
      notifyListeners();
      return;
    }
    final here = LatLng(f.lat, f.lon);
    final last = _lastAccepted;
    final lastAt = _lastAcceptedAt;
    final lastAcc = _lastAcceptedAcc;
    if (last == null || lastAt == null) {
      // First trusted reading of the session: the zero point for distance.
      _lastAccepted = here;
      _lastAcceptedAt = f.at ?? DateTime.now();
      _lastAcceptedAcc = acc;
      notifyListeners();
      return;
    }
    final movedM = _dist.as(LengthUnit.Meter, last, here);
    final dt = (f.at ?? DateTime.now()).difference(lastAt).inMilliseconds / 1000.0;
    // Two consecutive errors scatter around the true spot: their average is the
    // size of the circle the readings can wander in while standing still.
    // Movement smaller than that is noise, not walking - it is ignored.
    final noiseM = ((lastAcc ?? _maxAccuracyM) + acc) / 2;
    // ... and it cannot be faster than the mode allows (plus a few metres of
    // slack): anything bigger is a GPS jump, thrown away instead of counted.
    final limitM = _maxSpeed * (dt <= 0 ? 1 : dt) + 15;
    if (movedM > limitM) {
      // Do not adopt the jump: keep the old anchor so one bad reading cannot
      // weld itself into the route.
      notifyListeners();
      return;
    }
    _lastAccepted = here;
    _lastAcceptedAt = f.at ?? DateTime.now();
    _lastAcceptedAcc = acc;
    if (movedM >= noiseM && movedM >= 0.5) {
      km += movedM / 1000;
      _appendPoint(here);
    }
    notifyListeners();
  }

  /// Joins a point onto the route line, but only when the person really moved
  /// (over ~8 m) - standing still would pile dots on one house.
  void _appendPoint(LatLng pt) {
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
    _clockTimer?.cancel();
    _clockTimer = null;
    unawaited(_posSub?.cancel());
    _posSub = null;
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
    _clockTimer?.cancel();
    unawaited(_posSub?.cancel());
    unawaited(_stepSub?.cancel());
    super.dispose();
  }
}
