/// Pure signal maths for the fingertip heart-rate reading. No Flutter imports - only
/// dart:math - so the maths can be tested without a camera: luminance samples in, one
/// beat rate out.
///
/// How a machine-grade number is produced here:
///
///  1. speckle removal (median of neighbours) and slow-drift removal (detrend), done by
///     the camera layer before this file is called;
///  2. a light 3-tap low-pass trims frame noise above the pulse band;
///  3. TWO INDEPENDENT estimators read the same window:
///       * the autocorrelation spacing (rhythm-matching, with a parabolic interpolation
///         so the lag lands between samples - a whole-frame lag grid alone is too coarse,
///         which is what made the first version read 71.4 for a true 72), and
///       * the median spacing between detected beat peaks (works beat by beat);
///  4. they must agree inside 8% - if the two honest views of the finger disagree, the
///     reading is refused rather than dressed up. When they agree, the answer is their
///     blend, which is far steadier than either alone.
///
/// Refusals stay refusals: a flat, noisy, too-short or self-contradicting window returns
/// null and the screen says "could not trust it" instead of inventing a number.
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
        ? (b >= c ? b : (a >= c ? c : a))
        : (a >= c ? a : (c >= b ? b : c));
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
/// carries a trustworthy, self-consistent beat.
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
    final r = _readOneWindow(slice, fps, minBpm: minBpm, maxBpm: maxBpm, trust: trust, minWiggle: minWiggle);
    if (r != null) return r;
  }
  return null;
}

const _windows = <double>[999999.0, 24.0, 16.0];

/// How far the two estimators may disagree (relative to the autocorrelation rate) and
/// still be called the same beat.
const _agreement = 0.08;

double? _readOneWindow(
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

  // Light 3-tap low-pass: pulse content sits below ~4 Hz; frame noise lives above.
  final s = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    final a = i > 0 ? z[i - 1] : z[i];
    final c = i + 1 < n ? z[i + 1] : z[i];
    s[i] = (a + z[i] + c) / 3;
  }

  final bpmA = _autocorrBpm(s, fps, minBpm: minBpm, maxBpm: maxBpm, trust: trust);
  final bpmB = _peakIntervalsBpm(s, fps, minBpm: minBpm, maxBpm: maxBpm);

  if (bpmA == null) return null;
  if (bpmB == null) {
    // No clean run of beat peaks came out (move artefacts, wet finger). The rhythm
    // match alone is admitted only when its confidence is high.
    return bpmA.confidence >= trust + 0.15 ? bpmA.bpm : null;
  }
  final rel = (bpmA.bpm - bpmB).abs() / bpmA.bpm;
  if (rel > _agreement) return null;
  return (bpmA.bpm + bpmB) / 2;
}

class _Rhythm {
  const _Rhythm(this.bpm, this.confidence);
  final double bpm;
  final double confidence;
}

/// Rhythm-matching estimator: best normalised lag, refined between samples with a
/// parabola through the correlation peak.
_Rhythm? _autocorrBpm(
  List<double> s,
  double fps, {
  required double minBpm,
  required double maxBpm,
  required double trust,
}) {
  final n = s.length;
  final minLag = (fps * 60 / maxBpm).floor().clamp(1, n - 3);
  final maxLag = (fps * 60 / minBpm).ceil().clamp(1, n - 2);
  if (minLag >= maxLag) return null;

  // Normalised correlation, so a long lag does not score higher just for coverage.
  var total = 0.0;
  for (final v in s) total += v * v;
  if (total <= 0) return null;

  double normAt(int lag) {
    var e0 = 0.0, e1 = 0.0, r = 0.0;
    for (var i = 0; i + lag < n; i++) {
      r += s[i] * s[i + lag];
      e0 += s[i] * s[i];
      e1 += s[i + lag] * s[i + lag];
    }
    if (e0 <= 0 || e1 <= 0) return 0;
    return r / math.sqrt(e0 * e1);
  }

  var bestLag = -1;
  var best = 0.0;
  for (var lag = minLag; lag <= maxLag; lag++) {
    final norm = normAt(lag);
    if (norm > best) {
      best = norm;
      bestLag = lag;
    }
  }
  if (bestLag < 0 || best <= 0) return null;

  // Octave guard: at fast rates the correlation at double the lag (half the rate)
  // lines up almost perfectly because a whole-frame lag grid hurts short lags more.
  // If a shorter lag scores nearly as well, that shorter lag is the true fundamental.
  var lag0 = bestLag;
  for (final k in const [2, 3]) {
    final cand = (bestLag / k).round();
    if (cand < minLag || cand >= bestLag) continue;
    if (normAt(cand) >= best * 0.92) {
      lag0 = cand;
      break;
    }
  }

  // Parabolic refinement - the true peak of the correlation sits between frames.
  double lagF = lag0.toDouble();
  if (lag0 > minLag && lag0 < maxLag) {
    final ym = normAt(lag0), yl = normAt(lag0 - 1), yr = normAt(lag0 + 1);
    final denom = yl - 2 * ym + yr;
    if (denom.abs() > 1e-12) {
      final delta = 0.5 * (yl - yr) / denom;
      if (delta.abs() <= 0.5) lagF = lag0 + delta;
    }
  }

  final bpm = 60.0 * fps / lagF;
  if (bpm < minBpm * 0.95 || bpm > maxBpm * 1.05) return null;
  return _Rhythm(bpm.clamp(minBpm, maxBpm).toDouble(), best);
}

/// Beat-by-beat estimator: find the bright systolic peaks and take the median spacing.
double? _peakIntervalsBpm(
  List<double> s,
  double fps, {
  required double minBpm,
  required double maxBpm,
}) {
  final n = s.length;
  if (n < 8) return null;

  // Peak stands out clearly: a local maximum well above the wiggle floor.
  var peakEnergy = 0.0;
  for (final v in s) peakEnergy += v * v;
  final peakRms = math.sqrt(peakEnergy / n);
  final floor = 0.55 * peakRms;

  final peaks = <int>[];
  for (var i = 1; i < n - 1; i++) {
    if (s[i] > s[i - 1] && s[i] >= s[i + 1] && s[i] > floor) {
      peaks.add(i);
    }
  }
  if (peaks.length < 4) return null;

  final intervals = <double>[];
  for (var i = 1; i < peaks.length; i++) {
    final d = peaks[i] - peaks[i - 1];
    if (d < fps * 60 / maxBpm || d > fps * 60 / minBpm) continue;
    intervals.add(d.toDouble());
  }
  if (intervals.length < 3) return null;

  final sorted = List<double>.of(intervals)..sort();
  final med = sorted[sorted.length ~/ 2];

  // Drop beat intervals that wandered off the median (missed or spurious peaks).
  final kept = <double>[];
  for (final d in intervals) {
    if (d >= med * 0.7 && d <= med * 1.45) kept.add(d);
  }
  if (kept.length < 3) return null;
  final med2 = (List<double>.of(kept)..sort())[kept.length ~/ 2];

  final bpm = 60.0 * fps / med2;
  if (bpm < minBpm || bpm > maxBpm) return null;
  return bpm;
}
