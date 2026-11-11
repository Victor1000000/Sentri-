import 'dart:async';

import 'package:camera/camera.dart';

import 'heart_signal.dart';

/// Reads the pulse straight from the person, with no health app in between: the front
/// camera, with the fingertip pressed over it and the bright screen lighting the finger
/// from behind. Each heartbeat pushes a little more blood through the finger, which
/// changes how much light reflects back - the camera turns that into a brightness wiggle,
/// and the maths turns the wiggle into beats per minute.
///
/// Deliberately patient and honest: it records about thirty seconds, and returns null
/// (not a guess) whenever the wiggle is too weak or too messy to trust.
///
/// v36 accuracy work: the camera's exposure and focus are LOCKED before frames are read.
/// An auto-exposure that keeps hunting produces its own slow brightness waves that are
/// not the pulse at all - the single biggest source of "funny numbers". And the answer
/// must agree with itself: the take is scored in two halves, and a reading whose halves
/// disagree is refused, not averaged.
class HeartCamera {
  static const secondsTarget = 30;

  /// true after a run that never had a working camera or was not given permission -
  /// different advice on the screen than "the reading was not strong enough".
  bool cameraMissing = false;

  /// Frames that actually arrived last run. A run with zero frames means the camera
  /// stream never delivered anything - different advice than a weak pulse.
  int frames = 0;

  final _samples = <double>[];
  final _times = <double>[];
  final _sw = Stopwatch();
  CameraController? _controller;

  /// How many seconds the reading still needs - surfaced so the screen can count down.
  int secondsLeft = 0;

  /// The live controller while a measurement is on; the screen must show the preview so
  /// the inner camera keeps sending frames. Null when not measuring.
  CameraController? get controller => _controller;

  /// Runs one measurement. `onTick` fires about once a second with the seconds left.
  /// Returns the beats per minute, or null when nothing trustworthy came out.
  Future<int?> measure({void Function(int secondsLeft)? onTick}) async {
    await _close();
    _samples.clear();
    _times.clear();
    _sw
      ..reset()
      ..start();
    CameraDescription? cam;
    cameraMissing = false;
    frames = 0;
    try {
      final cams = await availableCameras();
      for (final c in cams) {
        if (c.lensDirection == CameraLensDirection.front) {
          cam = c;
          break;
        }
      }
      cam ??= cams.isEmpty ? null : cams.first;
    } catch (_) {
      cam = null;
    }
    if (cam == null) {
      cameraMissing = true;
      return null; // the screen shows the "camera not available" note
    }

    final ctrl = CameraController(
      cam,
      ResolutionPreset.low,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    try {
      await ctrl.initialize();
    } catch (_) {
      cameraMissing = true; // permission refused, or the camera refuses to open
      await ctrl.dispose();
      return null; // never pretend a number
    }
    _controller = ctrl;
    // Lock the exposure and the focus BEFORE the stream starts. Auto-exposure re-lightens
    // the frame whenever its average drifts, drawing waves that drown the tiny pulse;
    // auto-focus hunting blurs and brightens for the same reason. A locked camera turns
    // the finger into a steady lamp, so what wiggles is the blood. Both are best effort:
    // a phone that refuses the lock still measures with the free-running camera.
    try {
      await ctrl.setExposureMode(ExposureMode.locked);
    } catch (_) {}
    try {
      await ctrl.setFocusMode(FocusMode.locked);
    } catch (_) {}
    // No torch here: the front camera has none. The bright screen supplies the light;
    // the measure screen shows a big bright panel for exactly that.
    try {
      await ctrl.startImageStream(_onFrame);
    } catch (_) {
      cameraMissing = true;
      await _close();
      return null;
    }

    final wait = _measureFrames();
    final total = secondsTarget;
    while (_sw.elapsed < Duration(seconds: total)) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final left = total - _sw.elapsed.inSeconds;
      secondsLeft = left < 0 ? 0 : left;
      onTick?.call(secondsLeft);
      if (_sw.elapsed >= Duration(seconds: total)) break;
    }
    await wait;

    try {
      await ctrl.stopImageStream();
    } catch (_) {}
    await _close();

    // Skip the first ~2 seconds: that is when the finger press is still settling and
    // the exposure is still hunting - analysis runs only on the settled stream.
    var i0 = 0;
    while (i0 < _times.length && _times[i0] < 2.0) {
      i0++;
    }
    final samples = _samples.sublist(i0);
    final times = _times.sublist(i0);
    final n = samples.length;
    frames = _samples.length;
    if (n < 48 || times.isEmpty) return null;
    // The frame rate from the MEDIAN gap between frames, not from span/count: a few
    // dropped or bunched frames would skew an average, and every estimator below
    // divides by the frame rate.
    final fps = _fpsOf(times);
    if (fps <= 5) return null;
    final ys = detrend(smoothMedian3(samples), (fps * 1.5).round().clamp(3, n));
    // A gentler wiggle floor than the maths default: on dark themes and dim screens the
    // pulse is fainter in camera counts, and demanding more here read "no pulse" on
    // healthy fingers. The agreement checks still rule out junk.
    final bpm = bpmFromSamples(ys, fps, minWiggle: 0.4);
    if (bpm == null) return null;
    // The take must agree with ITSELF: score the first half and the second half
    // separately. Two halves that found different hearts mean the window carries
    // motion or light artefacts, not a pulse - refuse rather than average.
    final half = samples.length ~/ 2;
    if (half >= 60) {
      final ya = detrend(smoothMedian3(samples.sublist(0, half)), (fps * 1.5).round().clamp(3, half));
      final yb = detrend(smoothMedian3(samples.sublist(half)), (fps * 1.5).round().clamp(3, samples.length - half));
      final a = bpmFromSamples(ya, fps, minWiggle: 0.4);
      final b = bpmFromSamples(yb, fps, minWiggle: 0.4);
      if (a != null && b != null) {
        final rel = (a - b).abs() / ((a + b) / 2);
        if (rel > 0.12) return null; // the finger moved, or the light lied: no number
      }
    }
    return bpm.round().clamp(30, 220);
  }

  /// Frames per second from the median inter-frame gap - robust to dropped frames.
  double _fpsOf(List<double> times) {
    if (times.length < 2) return 0;
    final gaps = <double>[];
    for (var i = 1; i < times.length; i++) {
      final d = times[i] - times[i - 1];
      if (d > 0.0005) gaps.add(d); // ignore same-timestamp bunching
    }
    if (gaps.isEmpty) return 0;
    gaps.sort();
    final med = gaps[gaps.length ~/ 2];
    if (med <= 0) return 0;
    return 1 / med;
  }

  void _onFrame(CameraImage img) {
    if (_controller == null) return;
    if (img.planes.isEmpty || img.width <= 0 || img.height <= 0) return;
    final p = img.planes.first;
    final b = p.bytes;
    final stride = p.bytesPerRow;
    if (stride < img.width) return;
    // Centre quarter of the frame: that is where the pressed fingertip sits.
    final h = img.height, w = img.width;
    final y0 = h ~/ 4, y1 = h - h ~/ 4 - (h % 2);
    final x0 = w ~/ 4, x1 = w - w ~/ 4 - (w % 2);
    if (y1 <= y0 || x1 <= x0) return;
    var sum = 0;
    var cnt = 0;
    for (var y = y0; y < y1; y += 2) {
      final base = y * stride;
      for (var x = x0; x < x1; x += 2) {
        sum += b[base + x];
        cnt++;
      }
    }
    if (cnt == 0) return;
    _samples.add(sum / cnt);
    _times.add(_sw.elapsedMicroseconds / 1e6);
    frames = _samples.length;
  }

  /// Waits until the sample buffer stops growing for a beat (the stream has caught up),
  /// at most a small extra moment past the target window.
  Future<void> _measureFrames() async {
    var stable = 0;
    var lastLen = _samples.length;
    final limit = DateTime.now().add(const Duration(seconds: 4));
    while (DateTime.now().isBefore(limit)) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final len = _samples.length;
      if (len == lastLen) {
        stable++;
      } else {
        stable = 0;
        lastLen = len;
      }
      if (stable >= 3 && len >= 60) return;
    }
  }

  Future<void> _close() async {
    final c = _controller;
    _controller = null;
    if (c == null) return;
    try {
      await c.dispose();
    } catch (_) {}
  }
}
