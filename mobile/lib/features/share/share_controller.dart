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

  ShareInfo? _active;
  String? _stopping;
  int _epoch = 0;
  Cancelable? _tick, _stopRetry;

  /// The share that is running now, or null.
  ShareInfo? get active => _active;

  /// True while a Stop is waiting for the server to confirm.
  bool get stopPending => _stopping != null;

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
      try {
        await api.updateShare(a.id, fix);
      } on ApiHttpError catch (e) {
        if (e.status == 404) return _end(); // ended or expired on the server
      } catch (_) {
        // Offline: try again at the next tick.
      }
    }
    if (epoch == _epoch) _schedule(epoch, _interval(pct));
  }

  void _end() {
    _epoch++;
    _tick?.cancel();
    _active = null;
    unawaited(_save());
    notifyListeners();
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
    _tick?.cancel();
    _stopRetry?.cancel();
    super.dispose();
  }
}
