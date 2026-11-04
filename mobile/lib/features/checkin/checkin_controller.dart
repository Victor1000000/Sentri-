import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/storage/key_value_store.dart';
import '../../core/timers.dart';
import '../sos/sos_controller.dart';

/// "Check on me": the person sets a window before a trip or night walk. If they have not marked
/// themselves safe when the window ends, a real alert goes to their contacts through the normal
/// SOS machine - same 5-second cancel window, same retry-on-offline, same pending-save, so an app
/// kill or phone restart cannot swallow it.
class CheckInController extends ChangeNotifier {
  CheckInController({required this.sos, required this.timers, required KeyValueStore store}) : _store = store;

  final SosController sos;
  final Timers timers;
  final KeyValueStore _store;
  static const _k = 'checkin.endsAtMs.v1';

  /// How old a saved window found at start-up may be and still fire. Older than this was meant
  /// for a moment long past, so it is dropped quietly instead of raising a stale alarm.
  static const _grace = Duration(minutes: 10);

  DateTime? _endsAt;
  Cancelable? _timer;

  DateTime? get endsAt => _endsAt;
  bool get running => _endsAt != null;

  /// Re-arms a window saved before the app last closed, or fires it if it ended recently.
  Future<void> resume() async {
    final raw = await _store.read(_k);
    if (raw == null || raw.isEmpty) return;
    final ms = int.tryParse(raw);
    if (ms == null) {
      await _store.delete(_k);
      return;
    }
    final saved = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = timers.now();
    if (saved.isAfter(now)) {
      if (sos.phase != SosPhase.idle) return; // an alert already runs; the check has lost its job
      _endsAt = saved;
      notifyListeners();
      _arm(saved.difference(now));
      return;
    }
    if (now.difference(saved) <= _grace) {
      await _clearSaved();
      await _fire();
      return;
    }
    await _clearSaved();
  }

  /// Arms the window. While an alert already runs (an SOS), starting is skipped: the contacts
  /// are already being alerted.
  Future<void> start(Duration window) async {
    if (sos.phase != SosPhase.idle) return;
    _timer?.cancel();
    final ends = timers.now().add(window);
    _endsAt = ends;
    await _store.write(_k, '${ends.millisecondsSinceEpoch}');
    notifyListeners();
    _arm(window);
  }

  /// The person marked themselves safe (or wants the watch off): nothing is sent.
  Future<void> cancel() async {
    _timer?.cancel();
    _timer = null;
    _endsAt = null;
    await _store.delete(_k);
    notifyListeners();
  }

  void _arm(Duration remaining) {
    _timer?.cancel();
    _timer = timers.once(remaining, () => unawaited(_fire()));
  }

  Future<void> _fire() async {
    _timer = null;
    await _clearSaved();
    final sos = this.sos;
    _endsAt = null;
    notifyListeners();
    if (sos.phase == SosPhase.idle) await sos.trigger('checkin');
  }

  Future<void> _clearSaved() => _store.delete(_k);

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
