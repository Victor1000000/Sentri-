/// Pure signal maths for the fingertip heart-rate reading. No Flutter imports - only
/// dart:math - so the maths can be tested without a camera: luminance samples in, one
/// beat rate out.
///
/// How a machine-grade number is produced here:
///
///  1. speckle removal (median of neighbours) and slow-drift removal (detrend), done by
///     the camera layer before this file is called;
///  2. a light 3-tap low-pass trims frame noise above the pulse band;
///  3. THREE INDEPENDENT estimators read the same window:
///       * the autocorrelation spacing (rhythm-matching, with a parabolic interpolation
///         so the lag lands between samples - a whole-frame lag grid alone is too coarse,
///         which is what made the first version read 71.4 for a true 72),
///       * the median spacing between detected beat peaks (works beat by beat), and
///       * a Hann-windowed FFT spectrum (zero-padded for a fine grid): the frequency
///         whose line stands far above the band's noise floor is the heart. The
///         spectrum cannot "double" a rate the way a lag grid can - harmonics only
///         add smaller side peaks - so it is the arbiter of octave errors.
///  4. an estimator that landed on double or half the others' rate is aligned to the
///     spectral octave, then the estimates are clustered: a reading is only returned
///     when at least TWO views agree within 8%. One lone view may carry the reading
///     only when the rhythm match itself is confident.
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

/// How far two estimators may disagree (relative to either rate) and still be called
/// the same beat.
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

  final rhythm = _autocorrBpm(s, fps, minBpm: minBpm, maxBpm: maxBpm);
  var a = rhythm?.bpm;
  var b = _peakIntervalsBpm(s, fps, minBpm: minBpm, maxBpm: maxBpm);
  var c = _spectralBpm(s, fps, minBpm: minBpm, maxBpm: maxBpm);

  // Octave alignment: if one view landed on double or half of the spectral view's
  // rate, the spectral view wins the octave (a lag grid can double a rate; a peak
  // counter can count notches; the spectrum's fundamental cannot lie that way).
  a = _alignOctave(a, c);
  b = _alignOctave(b, c);

  // Cluster the surviving views. A reading needs TWO independent views that agree.
  final views = <double>[];
  for (final v in [a, b, c]) {
    if (v != null) views.add(v);
  }
  if (views.isNotEmpty) {
    var bestCluster = <double>[];
    for (final v in views) {
      final cl = [for (final w in views) if ((w - v).abs() / v <= _agreement) w];
      if (cl.length > bestCluster.length) bestCluster = cl;
    }
    if (bestCluster.length >= 2) {
      return bestCluster.reduce((x, y) => x + y) / bestCluster.length;
    }
  }
  // A single view may carry the reading when the rhythm match is itself confident -
  // the parabolic interpolation and the octave guard keep it honest. (The v36
  // +0.05 bar read healthy fingers as "not strong enough" on dark screens; `trust`
  // alone is still a firm bar, and the cluster + self-agreement checks above stay.)
  if (rhythm != null && rhythm.confidence >= trust) return rhythm.bpm;
  return null;
}

/// Brings [x] into [y]'s octave when they sit a factor of two (or half) apart.
/// A factor of three is left alone - a genuine disagreement, not an octave slip.
double? _alignOctave(double? x, double? y) {
  if (x == null || y == null || y <= 0) return x;
  final ratio = x / y;
  if (ratio >= 1.8 && ratio <= 2.25) return y; // x doubled the rate
  if (ratio >= 1 / 2.25 && ratio <= 1 / 1.8) return 2 * y; // x halved the rate
  return x;
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
  // The bar is deliberately high (0.96): a dicrotic wave can look tempting at half
  // the true period, and calling it the fundamental doubles the reading.
  var lag0 = bestLag;
  for (final k in const [2, 3]) {
    final cand = (bestLag / k).round();
    if (cand < minLag || cand >= bestLag) continue;
    if (normAt(cand) >= best * 0.96) {
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

  // Collect every candidate, then apply a refractory rule: within one shortest-possible
  // beat, only the tallest candidate survives. A wobbly real waveform makes several small
  // maxima around each main beat, and counting them as beats wrecks the spacing.
  final minGap = (fps * 60 / maxBpm).floor();
  final candidates = <int>[];
  for (var i = 1; i < n - 1; i++) {
    if (s[i] > s[i - 1] && s[i] >= s[i + 1] && s[i] > floor) {
      candidates.add(i);
    }
  }
  final peaks = <int>[];
  var lastKept = -minGap - 1;
  for (final i in candidates) {
    if (i - lastKept <= minGap) {
      // Two candidates inside one beat window: keep the taller one.
      if (peaks.isNotEmpty && s[i] > s[peaks.last]) {
        peaks[peaks.length - 1] = i;
        lastKept = i;
      }
      continue;
    }
    peaks.add(i);
    lastKept = i;
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

// ---- the spectral view ----

/// Hann-windowed, zero-padded FFT: the frequency in the pulse band whose line stands
/// clearly above the band's noise floor. Unlike a lag grid, a spectrum does not put
/// phantom peaks at half the true period - harmonics appear as smaller lines at
/// MULTIPLES of the rate, never at a fraction of it - so this view arbitrates the
/// octave errors the other two can make.
double? _spectralBpm(
  List<double> s,
  double fps, {
  required double minBpm,
  required double maxBpm,
}) {
  final n = s.length;
  if (n < 64 || fps <= 0) return null;
  var m = 1;
  while (m < 2 * n) {
    m <<= 1;
    if (m > 16384) break; // plenty: even 16384 bins is a fraction of a bpm here
  }
  final re = List<double>.filled(m, 0);
  final im = List<double>.filled(m, 0);
  for (var i = 0; i < n; i++) {
    // Hann window: the take is a snippet of an endless stream, and a hard cut at
    // both ends would smear one sharp line into a wide skirt.
    re[i] = s[i] * 0.5 * (1 - math.cos(2 * math.pi * i / (n - 1)));
  }
  _fft(re, im);
  final binHz = fps / m;
  final kLo = (minBpm / 60 / binHz).floor().clamp(1, m ~/ 2 - 2);
  final kHi = (maxBpm / 60 / binHz).ceil().clamp(kLo + 1, m ~/ 2 - 1);

  var bestK = -1;
  var bestMag = -1.0;
  final band = <double>[];
  double magAt(int k) => math.sqrt(re[k] * re[k] + im[k] * im[k]);
  for (var k = kLo; k <= kHi; k++) {
    final mag = magAt(k);
    band.add(mag);
    if (mag > bestMag) {
      bestMag = mag;
      bestK = k;
    }
  }
  if (bestK < 0 || bestMag <= 0) return null;
  // The line must stand above the band's noise floor: the median magnitude of the
  // band, computed away from the peak's own skirts (plus or minus 2 bins).
  final floorSorted = List<double>.of(band)..sort();
  final noise = floorSorted[floorSorted.length ~/ 2];
  if (noise <= 0 || bestMag / noise < 3.0) return null;

  // Parabolic refinement: the true line sits between bins.
  double kF = bestK.toDouble();
  final ym = bestMag, yl = magAt(bestK - 1), yr = magAt(bestK + 1);
  final denom = yl - 2 * ym + yr;
  if (denom.abs() > 1e-12) {
    final delta = 0.5 * (yl - yr) / denom;
    if (delta.abs() <= 0.5) kF = bestK + delta;
  }
  final bpm = 60.0 * kF * binHz;
  if (bpm < minBpm || bpm > maxBpm) return null;
  return bpm;
}

/// In-place radix-2 FFT (iterative Cooley-Tukey). [re] and [im] must be the same
/// length, a power of two.
void _fft(List<double> re, List<double> im) {
  final n = re.length;
  if (n <= 1) return;
  // Bit-reversal permutation first.
  var j = 0;
  for (var i = 1; i < n; i++) {
    var bit = n >> 1;
    for (; (j & bit) != 0; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      final tr = re[i]; re[i] = re[j]; re[j] = tr;
      final ti = im[i]; im[i] = im[j]; im[j] = ti;
    }
  }
  for (var len = 2; len <= n; len <<= 1) {
    final ang = -2 * math.pi / len;
    final wr = math.cos(ang), wi = math.sin(ang);
    final half = len >> 1;
    for (var i = 0; i < n; i += len) {
      var cr = 1.0, ci = 0.0;
      for (var k = 0; k < half; k++) {
        final ar = re[i + k], ai = im[i + k];
        final p = i + k + half;
        final vr = re[p] * cr - im[p] * ci;
        final vi = re[p] * ci + im[p] * cr;
        re[i + k] = ar + vr;
        im[i + k] = ai + vi;
        re[p] = ar - vr;
        im[p] = ai - vi;
        final ncr = cr * wr - ci * wi;
        ci = cr * wi + ci * wr;
        cr = ncr;
      }
    }
  }
}
