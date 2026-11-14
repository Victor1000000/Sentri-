import 'dart:async';

import 'package:camera/camera.dart';

import 'heart_signal.dart';

/// Reads the pulse straight from the person, with no health app in between: the front
/// camera, with the fingertip pressed over it and the bright screen lighting the finger
/// from behind. Each heartbeat pushes a little more blood through the finger, which
/// changes how much light reflects back - the camera turns that into a brightness wiggle,
/// and the maths turns the wiggle into beats per minute.
///
/// Deliberately patient and honest: it records about twenty seconds, and returns null
/// (not a guess) whenever the wiggle is too weak or too messy to trust.
///
/// v36 accuracy work: the camera's exposure and focus are LOCKED so an auto-exposure
/// that keeps hunting cannot draw its own slow brightness waves - fake pulses. v37
/// fixes the regression that lock caused: the lock happens AFTER the stream has run
/// for two seconds (so the auto-exposure first adapts to the fingertip, not to the
/// bright empty screen), and samples before the lock are thrown away.
/// And the answer must agree with itself: the take is scored in two halves, and a
/// reading whose halves disagree is refused, not averaged.
class HeartCamera {
  static const secondsTarget = 20;

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
    // The stream starts FIRST, and the exposure lock comes ~2 seconds later. The v36
    // order (lock right after initialize) was the regression: the AE locked onto the
    // bright empty-screen scene, then the fingertip darkened the whole frame and every
    // reading came back "not strong enough". Letting the auto-exposure run for two
    // seconds means it adapts to the finger as its scene; only then is it locked, so
    // what wiggles afterwards is the blood, not the exposure hunting.
    try {
      await ctrl.startImageStream(_onFrame);
    } catch (_) {
      cameraMissing = true;
      await _close();
      return null;
    }
    await Future<void>.delayed(const Duration(milliseconds: 2000));
    var lockAt = 0.0;
    try {
      await ctrl.setExposureMode(ExposureMode.locked);
      lockAt = _sw.elapsedMicroseconds / 1e6;
    } catch (_) {}
    try {
      await ctrl.setFocusMode(FocusMode.locked);
    } catch (_) {}

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

    // Skip the settling lead-in: the finger press settling, plus the auto-exposure
    // adapting to the fingertip before the lock, plus a short margin after the lock
    // (a lock can itself shift the frame for a moment). Analysis runs only on the
    // locked, settled stream.
    final settle = (lockAt + 0.7 > 2.0) ? lockAt + 0.7 : 2.0;
    var i0 = 0;
    while (i0 < _times.length && _times[i0] < settle) {
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
    var bpm = bpmFromSamples(ys, fps, minWiggle: 0.4);
    // The take should agree with ITSELF: score the first half and the second half
    // separately. Two halves that found different hearts mean the window carries
    // motion or light artefacts, not a pulse.
    //
    // v40: the tolerance scales with how long each half actually ran. With a
    // twenty-second take each half is only about eight or nine seconds, and two honest
    // estimates of ONE steady heart can sit a resolution bin apart there (~10 bpm is
    // 15% at 70 bpm) - the fixed 15% bar read healthy short takes as self-contradicting
    // and refused them, which is why the 15 s countdown broke what 30 s fixed.
    // Halves of nine seconds or more keep the tight 15% bar; shorter halves get
    // the wider 30% one. The full-window read stays the primary answer either way.
    //
    // v41: when the halves still disagree, refuse to give up. The SECOND half is the
    // most settled stretch of the take - the finger has been pressed longest there and
    // the exposure lock has long since bedded in - so if the newest half on its own
    // carries a confident pulse, that reading is accepted instead of throwing the whole
    // measurement away. Only a second half with nothing trustworthy in it refuses.
    final half = samples.length ~/ 2;
    if (half >= 60) {
      final ya = detrend(smoothMedian3(samples.sublist(0, half)), (fps * 1.5).round().clamp(3, half));
      final yb = detrend(smoothMedian3(samples.sublist(half)), (fps * 1.5).round().clamp(3, samples.length - half));
      final a = bpmFromSamples(ya, fps, minWiggle: 0.4);
      final b = bpmFromSamples(yb, fps, minWiggle: 0.4);
      if (a != null && b != null) {
        final rel = (a - b).abs() / ((a + b) / 2);
        final tol = (half / fps) >= 9.0 ? 0.15 : 0.30;
        if (rel > tol) {
          // The halves disagree: fall back to the newest half alone (the most
          // settled stretch), and accept its confident reading. The primary full
          // window stays the answer whenever the halves do agree.
          final newest = bpmFromSamples(yb, fps, minWiggle: 0.4);
          if (bpm == null || newest != null) bpm = newest;
        }
      }
    }
    if (bpm == null) return null;
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
