import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:sentri/features/health/heart_signal.dart';

/// Synthetic fingertip-pulse signal: 72 beats per minute sampled at 25 frames per
/// second for `secs`, with slow drift (like the light changing) and noise on top.
List<double> fakeFingertipSignal(double bpm, double fps, double secs, [double noise = 6.0]) {
  final rnd = math.Random(7);
  final n = (fps * secs).round();
  final out = <double>[];
  for (var i = 0; i < n; i++) {
    final t = i / fps;
    final pulse = math.sin(2 * math.pi * (bpm / 60) * t) * 24.0;
    final drift = 6.0 * math.sin(2 * math.pi * 0.05 * t) + t * 0.4;
    out.add(128.0 + drift + pulse + (rnd.nextDouble() - 0.5) * noise);
  }
  return out;
}

void main() {
  test('a clean fingertip signal comes out near the true rate', () {
    const fps = 25.0;
    final ys = detrend(fakeFingertipSignal(72, fps, 30), (fps * 1.5).round());
    final bpm = bpmFromSamples(ys, fps);
    expect(bpm, isNotNull);
    expect(bpm!, greaterThanOrEqualTo(68));
    expect(bpm, lessThanOrEqualTo(76));
  });

  test('a faster pulse is found as faster', () {
    const fps = 25.0;
    final a = detrend(fakeFingertipSignal(60, fps, 30), (fps * 1.5).round());
    final b = detrend(fakeFingertipSignal(95, fps, 30), (fps * 1.5).round());
    final ba = bpmFromSamples(a, fps);
    final bb = bpmFromSamples(b, fps);
    expect(ba, isNotNull);
    expect(bb, isNotNull);
    expect(bb!, greaterThan(ba!));
  });

  test('flat noise is not dressed up as a pulse', () {
    const fps = 25.0;
    final rnd = math.Random(3);
    final flat = List<double>.generate(750, (_) => 128.0 + (rnd.nextDouble() - 0.5) * 0.4);
    expect(bpmFromSamples(detrend(flat, 38), fps), isNull);
  });

  test('too-short data is refused', () {
    expect(bpmFromSamples(detrend(<double>[130, 131, 130, 129, 130], 2), 25.0), isNull);
  });
}
