/// Pure signal maths for the fingertip heart-rate reading. No imports at all, so the
/// maths can be tested without a camera: luminance samples in, one beat rate out.
///
/// How it works: blood flowing under the skin changes how much light the finger
/// reflects. The camera sees that as tiny brightness swings. This file turns those
/// swings into beats per minute: blow away single-frame speckle, drop the slow drift,
/// check that the remaining wiggle is strong enough to trust, then find the swing
/// spacing that best correlates with itself - that spacing, in seconds, is the beat.
///
/// The search is patient: if the whole take does not give a confident answer, the same
/// search runs again on its most recent slices, where the finger press has usually
/// settled most.
library;

import 'dart:math' as math;

/// Median of each sample and its two neighbours: kills one-frame white speckle
/// (auto-exposure hiccups) without smearing the pulse rhythm.
List<double> smoothMedian3(List<double> xs) {
  final n = xs.length;
  if (n == 0) return <double>[];
  final out = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    final a = i > 0 ? xs[i - 1] : xs[i];
    final b = xs[i];
    final c = i + 1 < n ? xs[i + 1] : xs[i];
    final v = a >= b
        ? (b >= c
            ? b
            : (a >= c ? c : a))
        : (a >= c
            ? a
            : (c >= b ? b : c));
    out[i] = v;
  }
  return out;
}

/// Removes slow drift (lighting changes, the finger pressing in and out): shifts each
/// sample by the mean of the samples within `window` around it, keeping only the
/// faster wiggle.
List<double> detrend(List<double> xs, int window) {
  final n = xs.length;
  if (n == 0) return <double>[];
  final w = window < 1 ? 1 : (window > n ? n : window);
  final pre = List<double>.filled(n + 1, 0);
  for (var i = 0; i < n; i++) pre[i + 1] = pre[i] + xs[i];
  final out = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    var lo = i - w + 1;
    if (lo < 0) lo = 0;
    var hi = i + w;
    if (hi > n) hi = n;
    out[i] = xs[i] - (pre[hi] - pre[lo]) / (hi - lo);
  }
  return out;
}

/// Estimates the pulse in beats per minute. Returns null when no slice of the take
/// looks trustworthy - the app must show "could not read it" rather than invent a
/// number.
double? bpmFromSamples(
  List<double> ys,
  double fps, {
  double minBpm = 40,
  double maxBpm = 180,
  double trust = 0.18,
  double minWiggle = 0.6,
}) {
  if (ys.length < 8 || fps <= 0) return null;

  // The whole take first; then its most recent slices, where the finger press has
  // usually settled most. Whichever slice gives a confident answer wins.
  for (final seconds in _windows) {
    final take = (fps * seconds).round();
    final slice = take < ys.length ? ys.sublist(ys.length - take) : ys;
    if (slice.length < 40) continue;
    final r = _bpmOneWindow(slice, fps, minBpm: minBpm, maxBpm: maxBpm, trust: trust, minWiggle: minWiggle);
    if (r != null) return r;
  }
  return null;
}

const _windows = <double>[999999.0, 24.0, 16.0];

/// One autocorrelation search on one slice.
double? _bpmOneWindow(
  List<double> ys,
  double fps, {
  required double minBpm,
  required double maxBpm,
  required double trust,
  required double minWiggle,
}) {
  final n = ys.length;
  if (n < 8) return null;

  // Zero-mean.
  var mean = 0.0;
  for (final y in ys) mean += y;
  mean /= n;
  final z = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) z[i] = ys[i] - mean;

  // A real fingertip pulse makes an obvious wiggle in camera counts; flat light means
  // there is no reading to take.
  var energy = 0.0;
  for (final v in z) energy += v * v;
  final rms = math.sqrt(energy / n);
  if (rms < minWiggle) return null;

  final minLag = (fps * 60 / maxBpm).floor().clamp(1, n - 1);
  final maxLag = (fps * 60 / minBpm).ceil().clamp(1, n - 1);
  if (minLag >= maxLag) return null;

  var r0 = 0.0;
  for (var i = 0; i < n; i++) r0 += z[i] * z[i];

  var bestLag = -1;
  var best = 0.0;
  for (var lag = minLag; lag <= maxLag; lag++) {
    var s = 0.0;
    for (var i = 0; i + lag < n; i++) s += z[i] * z[i + lag];
    if (s > best) {
      best = s;
      bestLag = lag;
    }
  }
  if (bestLag < 0 || r0 <= 0) return null;
  if (best / r0 < trust) return null;
  final bpm = 60.0 * fps / bestLag;
  if (bpm < minBpm || bpm > maxBpm) return null;
  return bpm;
}
