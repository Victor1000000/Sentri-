import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';

/// Speaks route instructions with the phone's own voice engine. Chosen over a bundled or
/// generated service on purpose: it is free, needs no data connection, and every Android
/// phone already has one installed (Google TTS) - exactly what an emergency app should lean
/// on. The cloud voice studios need an account, a paid key or internet on every sentence,
/// which a safety app cannot depend on. So instead the best speaker already living on the
/// phone is chosen: the Nigerian English voice when the phone carries one, then Google's
/// network-quality voices, which read far more human than the plain default voice.
class StepVoice {
  StepVoice() {
    // Warm the engine up the moment the map exists, so the first instruction is
    // spoken at once instead of after the voice list is read.
    unawaited(_ensure());
  }
  final _tts = FlutterTts();
  Future<void>? _warming;

  Future<void> _ensure() => _warming ??= _setup();

  /// Ranks an installed voice so the calmer, more human ones win. `name` and `locale`
  /// come straight from the engine's own list, and every read is guarded, so a voice
  /// entry shaped differently can never crash the map.
  static int _score(Map<dynamic, dynamic> v) {
    final name = '${v['name'] ?? ''}'.toLowerCase();
    final locale = '${v['locale'] ?? v['language'] ?? ''}'.toLowerCase();
    final quality = '${v['quality'] ?? ''}'.toLowerCase();
    var s = 0;
    if (locale.startsWith('en-ng')) return 1000; // Nigerian English speaker, the natural pick here
    if (name.contains('en-ng') || name.contains('nigeria')) return 990;
    // Google's network voices are the human-sounding set: their names and
    // locales carry "network", and the engine also reports a quality field.
    if (name.contains('network') || locale.contains('network') || quality.contains('enhanced') || quality.contains('very_high')) s = 520;
    if (name.contains('-tpd') || name.contains('-twd') || name.contains('-gdb') || name.contains('-iom') || name.contains('-iol')) s = 420;
    // The old local legacy voice is the robotic one: keep it last.
    if (quality.contains('legacy') || name.contains('legacy')) s -= 100;
    if (locale.startsWith('en-us') || locale.startsWith('en-gb')) {
      s += 40;
    } else if (locale.startsWith('en')) {
      s += 20;
    }
    return s;
  }

  Future<void> _setup() async {
    try {
      // Google's own engine, when the phone has it: it carries the good network
      // voices the stock engine sometimes hides. Silent on phones without it.
      final engines = await _tts.getEngines;
      if (engines is List && engines.contains('com.google.android.tts')) {
        try {
          await _tts.setEngine('com.google.android.tts');
        } catch (_) {}
      }
    } catch (_) {}
    try {
      await _tts.setLanguage('en-US');
      await _tts.setSpeechRate(0.48);
      await _tts.setPitch(1.0);
      await _tts.setVolume(1.0);
      await _tts.setQueueMode(1); // wait for the previous line instead of cutting it
      final voices = await _tts.getVoices;
      if (voices is List && voices.isNotEmpty) {
        Map<dynamic, dynamic>? best;
        var bestScore = -1;
        for (final raw in voices) {
          if (raw is Map) {
            final s = _score(raw);
            if (s > bestScore) {
              best = raw;
              bestScore = s;
            }
          }
        }
        // Only leave the engine's default when the phone really has a better speaker.
        if (best != null && bestScore >= 40) {
          final name = '${best['name'] ?? ''}';
          final locale = '${best['locale'] ?? best['language'] ?? 'en-US'}';
          if (name.isNotEmpty) {
            await _tts.setVoice({'name': name, 'locale': locale});
          }
        }
      }
    } catch (_) {
      // No voice list (some engines): the plain default speaks and still works.
    }
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
