/// Pure signal maths for the fingertip heart-rate reading. No imports at all, so the
/// maths can be tested without a camera: luminance samples in, one beat rate out.
///
/// How it works: blood flowing under the skin changes how much light the finger
/// reflects. The camera sees that as tiny brightness swings. This file turns those
/// swings into beats per minute: drop the slow drift, check that the remaining wiggle
/// is strong enough to trust, then find the swing spacing that best correlates with
/// itself - that spacing, in seconds, is the beat.
library;

import 'dart:math' as math;

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

/// Estimates the pulse in beats per minute: finds the sample spacing (the "lag")
/// whose self-correlation is strongest inside the possible heart range, and returns
/// that spacing in seconds as a rate. Returns null when the signal is too short, too
/// flat, or too noisy to trust - the app must show "could not read it" rather than
/// invent a number.
double? bpmFromSamples(
  List<double> ys,
  double fps, {
  double minBpm = 40,
  double maxBpm = 180,
  double trust = 0.22,
  double minWiggle = 0.35,
}) {
  final n = ys.length;
  if (n < 8 || fps <= 0) return null;

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
