import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../../core/i18n/i18n.dart';
import '../../core/storage/key_value_store.dart';

/// The eight exercise awards. Each has its own drawn badge design, its own spoken
/// praise line and its own haptic "cheer" pattern, so unlocking different kinds feels
/// different on the hand and in the ear.
enum AwardKind {
  first,        // the first recorded session ever
  km5,          // five kilometres collected in total
  km10,         // ten kilometres collected in total
  km21,         // half-marathon distance collected in total
  steps10k,     // ten thousand steps in ONE session
  recordKm,     // longest single session ever (a record broken)
  recordSteps,  // most steps in one session ever (a record broken)
  sessions5,    // five sessions completed - the habit is real
}

String awardId(AwardKind k) => switch (k) {
      AwardKind.first => 'first',
      AwardKind.km5 => 'km5',
      AwardKind.km10 => 'km10',
      AwardKind.km21 => 'km21',
      AwardKind.steps10k => 'steps10k',
      AwardKind.recordKm => 'record_km',
      AwardKind.recordSteps => 'record_steps',
      AwardKind.sessions5 => 'sessions5',
    };

/// One earned award: which kind, and when it was earned.
class Award {
  const Award({required this.kind, required this.earnedAt});
  final AwardKind kind;
  final DateTime earnedAt;

  Map<String, String> toJson() => {'k': awardId(kind), 'at': earnedAt.toIso8601String()};
  static Award? fromJson(Map<String, dynamic> j) {
    final k = switch (j['k']) {
      'first' => AwardKind.first,
      'km5' => AwardKind.km5,
      'km10' => AwardKind.km10,
      'km21' => AwardKind.km21,
      'steps10k' => AwardKind.steps10k,
      'record_km' => AwardKind.recordKm,
      'record_steps' => AwardKind.recordSteps,
      'sessions5' => AwardKind.sessions5,
      _ => null,
    };
    if (k == null) return null;
    final at = DateTime.tryParse('${j['at'] ?? ''}');
    return Award(kind: k, earnedAt: at ?? DateTime.now());
  }
}

/// The person's award shelf, stored on this phone only. Earning is idempotent:
/// an award is added once and never re-earned.
class AwardStore extends ChangeNotifier {
  AwardStore(this._store);
  final KeyValueStore _store;
  static const _k = 'exercise.awards.v1';

  List<Award> _awards = const [];
  List<Award> get awards => _awards;
  bool has(AwardKind k) => _awards.any((a) => a.kind == k);

  Future<void> load() async {
    try {
      final raw = await _store.read(_k);
      if (raw == null || raw.isEmpty) return;
      final list = jsonDecode(raw);
      if (list is! List) return;
      final out = <Award>[];
      for (final el in list) {
        if (el is! Map<String, dynamic>) continue;
        final a = Award.fromJson(el);
        if (a != null) out.add(a);
      }
      _awards = out;
    } catch (_) {
      _awards = const [];
    }
    notifyListeners();
  }

  /// Adds every kind that is not already on the shelf. Returns the kinds that were
  /// NEW (so the session can celebrate exactly those).
  Future<List<AwardKind>> earnAll(List<AwardKind> kinds) async {
    final fresh = [for (final k in kinds) if (!has(k)) k];
    if (fresh.isEmpty) return const [];
    _awards = [..._awards, ...[for (final k in fresh) Award(kind: k, earnedAt: DateTime.now())]];
    try {
      await _store.write(_k, jsonEncode([for (final a in _awards) a.toJson()]));
    } catch (_) {
      // Storage hiccup: the session still shows; the next earn re-saves everything.
    }
    notifyListeners();
    return fresh;
  }
}

// ---------------------------------------------------------------------------
// the badge designs - each award gets its own look
// ---------------------------------------------------------------------------

class AwardLook {
  const AwardLook(this.icon, this.bgFrom, this.bgTo, this.ringNote, {this.round = true});
  final IconData icon;
  final Color bgFrom;
  final Color bgTo;

  /// True for round badges; false gives the shield look for records.
  final bool round;
  final String ringNote;
}

/// Distinct shapes and colour moods: journey badges are round medals in green
/// family, step badges are amber, and RECORD badges are the only shield shape,
/// in the alert-ish rose family - breaking a record should feel like a big deal.
AwardLook awardLook(AwardKind k) => switch (k) {
      AwardKind.first => const AwardLook(Icons.emoji_events_outlined, Color(0xFF2BB673), Color(0xFF178A52), 'start'),
      AwardKind.km5 => const AwardLook(Icons.directions_walk_outlined, Color(0xFF2BB673), Color(0xFF178A52), 'solid'),
      AwardKind.km10 => const AwardLook(Icons.directions_run_outlined, Color(0xFF1F9A8C), Color(0xFF0E6E62), 'solid'),
      AwardKind.km21 => const AwardLook(Icons.flag_outlined, Color(0xFF1F7A8C), Color(0xFF134B57), 'far'),
      AwardKind.steps10k => const AwardLook(Icons.steps_outlined, Color(0xFFE3A13A), Color(0xFFB27416), 'steps'),
      AwardKind.recordKm => const AwardLook(Icons.shield_outlined, Color(0xFFE2574C), Color(0xFFA83228), 'best', round: false),
      AwardKind.recordSteps => const AwardLook(Icons.shield_outlined, Color(0xFFE2574C), Color(0xFFA83228), 'best', round: false),
      AwardKind.sessions5 => const AwardLook(Icons.calendar_today_outlined, Color(0xFF6A5FF0), Color(0xFF4438C9), 'habit'),
    };

/// A drawn award badge: layered gradient disc or shield, an icon, and a tiny
/// ring shine - same drawn-in-code style as the guardian badges, no assets.
class AwardBadge extends StatelessWidget {
  const AwardBadge({super.key, required this.kind, this.size = 56, this.dim = false});
  final AwardKind kind;
  final double size;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final look = awardLook(kind);
    final shape = look.round ? BoxShape.circle : null;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: shape ?? BoxShape.rectangle,
        borderRadius: look.round ? null : BorderRadius.circular(size * 0.24),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: dim ? [look.bgFrom.withValues(alpha: 0.25), look.bgTo.withValues(alpha: 0.25)] : [look.bgFrom, look.bgTo],
        ),
        boxShadow: dim ? null : [BoxShadow(color: look.bgTo.withValues(alpha: 0.35), blurRadius: 12, offset: const Offset(0, 5))],
      ),
      child: Stack(alignment: Alignment.center, children: [
        // A thin ring just inside the edge, like a stamped medal's rim.
        Container(
          margin: EdgeInsets.all(size * 0.06),
          decoration: BoxDecoration(
            shape: shape ?? BoxShape.rectangle,
            borderRadius: look.round ? null : BorderRadius.circular(size * 0.19),
            border: Border.all(color: Colors.white.withValues(alpha: dim ? 0.15 : 0.45), width: 1.4),
          ),
        ),
        Icon(look.icon, size: size * 0.5, color: Colors.white.withValues(alpha: dim ? 0.5 : 1)),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// the celebration: badge, spoken praise, and a haptic cheer unique per award
// ---------------------------------------------------------------------------

/// Haptic "cheers": the pattern length and rhythm differ per award family -
/// one short tap for the first start, a stamping pair for milestones, a long
/// drumroll for broken records.
List<Duration> cheerRhythm(AwardKind k) => switch (k) {
      AwardKind.first => const [Duration(milliseconds: 300)],
      AwardKind.km5 || AwardKind.km10 => const [Duration(milliseconds: 220), Duration(milliseconds: 220), Duration(milliseconds: 220)],
      AwardKind.km21 => const [Duration(milliseconds: 260), Duration(milliseconds: 160), Duration(milliseconds: 260), Duration(milliseconds: 160), Duration(milliseconds: 260)],
      AwardKind.steps10k => const [Duration(milliseconds: 140), Duration(milliseconds: 140), Duration(milliseconds: 140), Duration(milliseconds: 140), Duration(milliseconds: 140), Duration(milliseconds: 140)],
      AwardKind.recordKm || AwardKind.recordSteps => const [Duration(milliseconds: 500), Duration(milliseconds: 200), Duration(milliseconds: 500), Duration(milliseconds: 200), Duration(milliseconds: 500)],
      AwardKind.sessions5 => const [Duration(milliseconds: 300), Duration(milliseconds: 200), Duration(milliseconds: 300)],
    };

final _tts = FlutterTts();

/// Speaks the praise in the app language when the phone can, and always plays the
/// haptic cheer. A celebration must never crash or block; everything is caught.
Future<void> playCelebration(AwardKind k, I18n i18n) async {
  // 1) the haptic cheer - always available.
  unawaited(_runCheer(k));
  // 2) the spoken praise (falls back silently when the phone has no voice for it).
  try {
    await _tts.setLanguage(i18n.code);
    await _tts.setPitch(1.1);
    await _tts.speak(i18n.t('award.${awardId(k)}_praise'));
  } catch (_) {
    // No TTS voice: the badge and the cheer still land.
  }
}

Future<void> _runCheer(AwardKind k) async {
  try {
    final steps = cheerRhythm(k);
    // Every second beat is the gap, so the pattern is played twice for impact.
    for (var round = 0; round < 2; round++) {
      for (var i = 0; i < steps.length; i++) {
        HapticFeedback.heavyImpact();
        await Future<void>.delayed(steps[i]);
      }
      if (round == 0) await Future<void>.delayed(const Duration(milliseconds: 350));
    }
  } catch (_) {}
}

/// The celebration overlay: the badge scales in, its name and what it took,
/// then a closed by one tap. Shown once per newly earned award.
Future<void> showAwardCelebration(BuildContext context, I18n i18n, AwardKind k) async {
  await playCelebration(k, i18n);
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      child: _AwardCard(kind: k, i18n: i18n),
    ),
  );
}

class _AwardCard extends StatefulWidget {
  const _AwardCard({required this.kind, required this.i18n});
  final AwardKind kind;
  final I18n i18n;
  @override
  State<_AwardCard> createState() => _AwardCardState();
}

class _AwardCardState extends State<_AwardCard> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 420))..forward();
  late final Animation<double> _scale = CurvedAnimation(parent: _anim, curve: Curves.easeOutBack);

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.i18n.t;
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ScaleTransition(
      scale: _scale,
      child: Material(
        color: dark ? const Color(0xFF1B1D23) : Colors.white,
        borderRadius: BorderRadius.circular(26),
        elevation: 8,
        shadowColor: Colors.black38,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(26, 26, 26, 20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            AwardBadge(kind: widget.kind, size: 96),
            const SizedBox(height: 16),
            Text(t('award.unlocked'), style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, letterSpacing: 1.2, color: cs.primary)),
            const SizedBox(height: 4),
            Text(t('award.${awardId(widget.kind)}_title'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
            const SizedBox(height: 8),
            Text(t('award.${awardId(widget.kind)}_desc'), textAlign: TextAlign.center, style: TextStyle(fontSize: 14.5, height: 1.4, color: cs.onSurface.withValues(alpha: 0.7))),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(t('award.nice'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          ]),
        ),
      ),
    );
  }
}
