import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';

/// Speaks route instructions with the phone's own voice engine. Chosen over a bundled or
/// generated voice on purpose: it is free, needs no data connection, and every Android phone
/// already has one installed (Google TTS) - exactly what an emergency app should lean on.
class StepVoice {
  final _tts = FlutterTts();
  bool _ready = false;

  Future<void> _ensure() async {
    if (_ready) return;
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    await _tts.setQueueMode(1); // wait for the previous line instead of cutting it
    _ready = true;
  }

  Future<void> say(String text) async {
    try {
      await _ensure();
      await _tts.speak(text);
    } catch (_) {
      // A missing voice engine must never break the map.
    }
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }
}
