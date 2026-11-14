import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/net/api.dart';
import '../../core/storage/key_value_store.dart';
import '../../core/timers.dart';
import '../battery/battery.dart';
import '../location/location.dart';

enum ShareStartOutcome { started, noneReachable, offline, failed }

/// Live location sharing: the person picks contacts, and their position goes to those contacts until
/// they stop, or until the safety limit passes. It runs in the always-on engine, so it keeps going
/// with the app closed and the screen off.
///
/// Stopping is never silent: if the phone is offline when the person taps Stop, position updates
/// stop at once, the screen says the stop is still pending, and it is retried until the server confirms.
///
/// While a share runs, the phone also keeps the story of it: every fresh fix is written into a
/// local track, and when the share ends the track joins the history. The share screen draws it
/// on a small map, the way a finished exercise session shows its route - the contacts who were
/// invited can later see where the person actually passed.
///
/// v41 breadcrumbs: while the share runs, each position update also carries a thinned
/// recent trail and the travel mode read off it, so the contacts' map shows the path the
/// person has walked, driven or flown - not just their latest dot.
class ShareController extends ChangeNotifier {
  ShareController({
    required this.api,
    required this.location,
    required this.battery,
    required this.timers,
    required this.store,
    this.dataSaver = _no,
  });

  final SentriApi api;
  final LocationSource location;
  final BatterySource battery;
  final Timers timers;
  final KeyValueStore store;
  final bool Function() dataSaver;

  static bool _no() => false;
  static const _k = 'share.active.v1';
  static const _tk = 'share.tracks.v1';

  ShareInfo? _active;
  String? _stopping;
  int _epoch = 0;
  Cancelable? _tick, _stopRetry;
  GeoFix? _prevFix;
  bool _travelFed = false;
  final TravelWatcher _travel = TravelWatcher();

  /// The route being drawn by the share that is running right now.
  List<List<double>> _track = const <List<double>>[];

  /// The share that is running now, or null.
  ShareInfo? get active => _active;

  /// True while a Stop is waiting for the server to confirm.
  bool get stopPending => _stopping != null;

  /// The trail drawn so far by the running share, oldest first - the map
  /// paints it live so the people invited see the path, not just the dot (v41).
  List<List<double>> get liveTrail => _track;

  /// How the person is travelling right now, read off the recent fixes with
  /// hysteresis (v41). Still until trusted speeds say otherwise.
  TravelMode get travelMode => _travel.mode;

  // ---- start ----

  Future<ShareStartOutcome> start(List<String> contactIds, {double hours = 8}) async {
    if (_active != null) return ShareStartOutcome.failed;
    final geo = await location.fix(highAccuracy: true, timeout: const Duration(seconds: 4)) ?? await location.lastKnown();
    try {
      final r = await api.startShare(contactIds, geo: geo, hours: hours);
      _begin(ShareInfo(id: r.id, expiresAt: r.expiresAt, contactIds: contactIds.where((c) => !r.unreachable.contains(c)).toList()));
      return ShareStartOutcome.started;
    } on ApiUnreachable {
      return ShareStartOutcome.offline;
    } on ApiHttpError catch (e) {
      return e.code == 'none_reachable' ? ShareStartOutcome.noneReachable : ShareStartOutcome.failed;
    } catch (_) {
      return ShareStartOutcome.failed;
    }
  }

  void _begin(ShareInfo s) {
    _active = s;
    _epoch++;
    _track = <List<double>>[]; // a fresh share draws a fresh line
    _prevFix = null;
    _travelFed = false;
    _travel.reset();
    unawaited(_save());
    notifyListeners();
    _schedule(_epoch, const Duration(seconds: 5));
  }

  /// Picks up a share that was running before the app or phone restarted.
  Future<void> resume() async {
    try {
      final shares = await api.activeShares();
      if (shares.isEmpty) {
        await store.delete(_k);
        return;
      }
      _begin(shares.first);
    } catch (_) {
      final raw = await store.read(_k);
      if (raw == null) return;
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        final exp = DateTime.fromMillisecondsSinceEpoch(j['e'] as int);
        if (exp.isAfter(timers.now())) _begin(ShareInfo(id: j['i'] as String, expiresAt: exp, contactIds: const []));
      } catch (_) {}
    }
  }

  Future<void> _save() async {
    final a = _active;
    if (a == null) {
      await store.delete(_k);
    } else {
      await store.write(_k, jsonEncode({'i': a.id, 'e': a.expiresAt.millisecondsSinceEpoch}));
    }
  }

  // ---- position updates ----

  Duration _interval(int pct) {
    var s = pct > 30 ? 15 : (pct > 15 ? 30 : 60);
    if (dataSaver()) s *= 2;
    return Duration(seconds: s);
  }

  void _schedule(int epoch, Duration d) {
    _tick?.cancel();
    _tick = timers.once(d, () => unawaited(_update(epoch)));
  }

  Future<void> _update(int epoch) async {
    final a = _active;
    if (epoch != _epoch || a == null) return;
    if (!a.expiresAt.isAfter(timers.now())) return _end();
    var pct = 50;
    try {
      pct = await battery.level();
    } catch (_) {}
    final fix = await location.fix(highAccuracy: pct > 15, timeout: const Duration(seconds: 8));
    if (epoch != _epoch || _active == null) return;
    if (fix != null) {
      _record(fix);
      try {
        await api.updateShare(
          a.id,
          fix,
          path: _thinnedPath(),
          mode: _travelFed ? _travel.mode.name : null,
        );
      } on ApiHttpError catch (e) {
        if (e.status == 404) return _end(); // ended or expired on the server
      } catch (_) {
        // Offline: try again at the next tick.
      }
    }
    if (epoch == _epoch) _schedule(epoch, _interval(pct));
  }

  /// The trail thinned for sending: at most 120 points spread evenly over what
  /// was recorded (plus the newest point last), so even a day-long share fits
  /// a small PUT body while the shape of the journey survives (v41).
  List<List<double>> _thinnedPath() {
    final t = _track;
    if (t.length <= 120) return t;
    final step = t.length / 120;
    final out = <List<double>>[for (var i = 0; i < 120; i++) t[(i * step).floor()]];
    out.add(t.last);
    return out;
  }

  /// One point on the story map. Points closer than about ten metres to the
  /// previous one are dropped, so a share spent sitting still stays a dot
  /// instead of a wall of points, and the line never grows past six hundred.
  void _record(GeoFix fix) {
    final prev = _prevFix;
    _prevFix = fix;
    if (prev != null) {
      final v = speedBetween(prev, fix);
      if (v != null) {
        _travelFed = true;
        _travel.feed(v);
      }
    }
    final last = _track.isEmpty ? null : _track.last;
    if (last != null && (fix.lat - last[0]).abs() < 0.0001 && (fix.lon - last[1]).abs() < 0.0001) return;
    if (_track.length >= 600) return;
    _track.add([fix.lat, fix.lon]);
    notifyListeners(); // the map paints the new breadcrumb at once (v41)
  }

  void _end() {
    final id = _active?.id;
    _epoch++;
    _tick?.cancel();
    _active = null;
    unawaited(_save());
    unawaited(_flushTrack(id));
    notifyListeners();
  }

  /// The story of the share is written on the phone the moment the share ends:
  /// the points join the history under the share's id, and stories past the
  /// newest twenty are dropped so the store stays small. Purely local - it
  /// never blocks stopping, and a failure only costs the map, not the share.
  Future<void> _flushTrack(String? id) async {
    final pts = _track;
    _track = <List<double>>[];
    if (id == null || id.isEmpty || pts.length < 2) return;
    try {
      Map<String, dynamic> all = <String, dynamic>{};
      final raw = await store.read(_tk);
      if (raw != null) {
        final j = jsonDecode(raw);
        if (j is Map) all = Map<String, dynamic>.from(j);
      }
      all[id] = pts;
      while (all.length > 20) {
        all.remove(all.keys.first);
      }
      await store.write(_tk, jsonEncode(all));
    } catch (_) {}
  }

  /// The route a past share drew: [[lat, lon], ...]. Empty when the phone has
  /// no story for it - shares made before this version, or points lost to a
  /// restart mid-share.
  Future<List<List<double>>> trackPoints(String id) async {
    try {
      final raw = await store.read(_tk);
      if (raw == null) return const [];
      final j = jsonDecode(raw);
      if (j is Map) {
        final t = j[id];
        if (t is List) {
          return [
            for (final p in t)
              if (p is List && p.length >= 2) [(p[0] as num).toDouble(), (p[1] as num).toDouble()],
          ];
        }
      }
    } catch (_) {}
    return const [];
  }

  // ---- stop and extend ----

  /// Stops sending positions now, and keeps telling the server until it confirms.
  Future<void> stop() async {
    final a = _active;
    if (a == null) return;
    _stopping = a.id;
    _end();
    await _confirmStop(a.id);
  }

  Future<void> _confirmStop(String id) async {
    try {
      await api.stopShare(id);
      _stopping = null;
    } on ApiHttpError catch (e) {
      if (e.status == 404) _stopping = null; // already ended
    } catch (_) {
      _stopRetry?.cancel();
      _stopRetry = timers.once(const Duration(seconds: 10), () => unawaited(_confirmStop(id)));
    }
    notifyListeners();
  }

  Future<bool> extend({double hours = 1}) async {
    final a = _active;
    if (a == null) return false;
    try {
      final exp = await api.extendShare(a.id, hours);
      _active = ShareInfo(id: a.id, expiresAt: exp, contactIds: a.contactIds);
      unawaited(_save());
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    // A share still running when the screen goes away keeps its server side
    // alive (resume() picks it up), but the line drawn so far is worth keeping.
    final id = _active?.id;
    _tick?.cancel();
    _stopRetry?.cancel();
    if (id != null && _track.length >= 2) unawaited(_flushTrack(id));
    super.dispose();
  }
}
