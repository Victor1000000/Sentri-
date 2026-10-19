import 'dart:async';

/// Everything time-related goes through [Timers] so the alert logic can be tested without waiting.
abstract class Cancelable {
  void cancel();
}

abstract class Timers {
  DateTime now();
  Cancelable once(Duration delay, void Function() fn);
}

class _RealCancelable implements Cancelable {
  _RealCancelable(this._t);
  final Timer _t;
  @override
  void cancel() => _t.cancel();
}

class RealTimers implements Timers {
  const RealTimers();
  @override
  DateTime now() => DateTime.now();
  @override
  Cancelable once(Duration delay, void Function() fn) => _RealCancelable(Timer(delay, fn));
}
