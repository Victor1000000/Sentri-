import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../../core/i18n/i18n.dart';
import '../../core/storage/key_value_store.dart';

/// The twenty-five exercise awards. Each has its own drawn badge design, its own spoken
/// praise line and its own haptic "cheer" pattern, so unlocking different kinds feels
/// different on the hand and in the ear. The shelf shows all twenty-five, dim until
/// earned.
enum AwardKind {
  first,        // the first recorded session ever
  km2,          // two kilometres collected in total
  km5,          // five kilometres collected in total
  km10,         // ten kilometres collected in total
  km21,         // half-marathon distance collected in total
  km42,         // full-marathon distance collected in total
  km50,         // fifty kilometres collected in total
  km100,        // one hundred kilometres collected in total
  session5,     // five kilometres in ONE session
  session10,    // ten kilometres in ONE session
  steps5k,      // five thousand steps in ONE session
  steps10k,     // ten thousand steps in ONE session
  steps20k,     // twenty thousand steps in ONE session
  minutes30,    // thirty minutes in ONE session
  minutes60,    // a full hour in ONE session
  sessions5,    // five sessions completed - the habit is real
  sessions10,   // ten sessions completed
  sessions25,   // twenty-five sessions completed
  sessions50,   // fifty sessions completed
  streak3,      // three sessions inside seven days
  firstRun,     // the first RUN ever recorded
  firstWalk,    // the first WALK ever recorded
  firstBike,    // the first RIDE ever recorded
  recordKm,     // longest single session ever (a record broken)
  recordSteps,  // most steps in one session ever (a record broken)
}

String awardId(AwardKind k) => switch (k) {
      AwardKind.first => 'first',
      AwardKind.km2 => 'km2',
      AwardKind.km5 => 'km5',
      AwardKind.km10 => 'km10',
      AwardKind.km21 => 'km21',
      AwardKind.km42 => 'km42',
      AwardKind.km50 => 'km50',
      AwardKind.km100 => 'km100',
      AwardKind.session5 => 'session5',
      AwardKind.session10 => 'session10',
      AwardKind.steps5k => 'steps5k',
      AwardKind.steps10k => 'steps10k',
      AwardKind.steps20k => 'steps20k',
      AwardKind.minutes30 => 'minutes30',
      AwardKind.minutes60 => 'minutes60',
      AwardKind.sessions5 => 'sessions5',
      AwardKind.sessions10 => 'sessions10',
      AwardKind.sessions25 => 'sessions25',
      AwardKind.sessions50 => 'sessions50',
      AwardKind.streak3 => 'streak3',
      AwardKind.firstRun => 'first_run',
      AwardKind.firstWalk => 'first_walk',
      AwardKind.firstBike => 'first_bike',
      AwardKind.recordKm => 'record_km',
      AwardKind.recordSteps => 'record_steps',
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
      'km2' => AwardKind.km2,
      'km5' => AwardKind.km5,
      'km10' => AwardKind.km10,
      'km21' => AwardKind.km21,
      'km42' => AwardKind.km42,
      'km50' => AwardKind.km50,
      'km100' => AwardKind.km100,
      'session5' => AwardKind.session5,
      'session10' => AwardKind.session10,
      'steps5k' => AwardKind.steps5k,
      'steps10k' => AwardKind.steps10k,
      'steps20k' => AwardKind.steps20k,
      'minutes30' => AwardKind.minutes30,
      'minutes60' => AwardKind.minutes60,
      'sessions5' => AwardKind.sessions5,
      'sessions10' => AwardKind.sessions10,
      'sessions25' => AwardKind.sessions25,
      'sessions50' => AwardKind.sessions50,
      'streak3' => AwardKind.streak3,
      'first_run' => AwardKind.firstRun,
      'first_walk' => AwardKind.firstWalk,
      'first_bike' => AwardKind.firstBike,
      'record_km' => AwardKind.recordKm,
      'record_steps' => AwardKind.recordSteps,
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
/// family, step badges are amber, habit badges are indigo, movement firsts are
/// sky blue, long-haul badges are deep teal, the streak burns ember, and RECORD
/// badges are the only shield shape, in the alert-ish rose family - breaking a
/// record should feel like a big deal.
AwardLook awardLook(AwardKind k) => switch (k) {
      AwardKind.first => const AwardLook(Icons.emoji_events_outlined, Color(0xFF2BB673), Color(0xFF178A52), 'start'),
      AwardKind.km2 => const AwardLook(Icons.directions_walk_outlined, Color(0xFF4CC98A), Color(0xFF2BB673), 'solid'),
      AwardKind.km5 => const AwardLook(Icons.directions_walk_outlined, Color(0xFF2BB673), Color(0xFF178A52), 'solid'),
      AwardKind.km10 => const AwardLook(Icons.directions_run_outlined, Color(0xFF1F9A8C), Color(0xFF0E6E62), 'solid'),
      AwardKind.km21 => const AwardLook(Icons.flag_outlined, Color(0xFF1F7A8C), Color(0xFF134B57), 'far'),
      AwardKind.km42 => const AwardLook(Icons.tour_outlined, Color(0xFF1F7A8C), Color(0xFF134B57), 'far'),
      AwardKind.km50 => const AwardLook(Icons.route_outlined, Color(0xFF1F7A8C), Color(0xFF134B57), 'far'),
      AwardKind.km100 => const AwardLook(Icons.explore_outlined, Color(0xFF116B77), Color(0xFF0C4652), 'far'),
      AwardKind.session5 => const AwardLook(Icons.map_outlined, Color(0xFF25A69A), Color(0xFF0E6E62), 'solid'),
      AwardKind.session10 => const AwardLook(Icons.terrain_outlined, Color(0xFF1F9A8C), Color(0xFF0E6E62), 'solid'),
      AwardKind.steps5k => const AwardLook(Icons.stairs, Color(0xFFEDB54A), Color(0xFFE3A13A), 'steps'),
      AwardKind.steps10k => const AwardLook(Icons.stairs, Color(0xFFE3A13A), Color(0xFFB27416), 'steps'),
      AwardKind.steps20k => const AwardLook(Icons.stairs, Color(0xFFC98A1F), Color(0xFF8A5A0D), 'steps'),
      AwardKind.minutes30 => const AwardLook(Icons.timer_outlined, Color(0xFF3D8BF0), Color(0xFF2258C9), 'time'),
      AwardKind.minutes60 => const AwardLook(Icons.schedule_outlined, Color(0xFF3D8BF0), Color(0xFF2258C9), 'time'),
      AwardKind.sessions5 => const AwardLook(Icons.calendar_today_outlined, Color(0xFF6A5FF0), Color(0xFF4438C9), 'habit'),
      AwardKind.sessions10 => const AwardLook(Icons.event_available_outlined, Color(0xFF6A5FF0), Color(0xFF4438C9), 'habit'),
      AwardKind.sessions25 => const AwardLook(Icons.military_tech_outlined, Color(0xFF5A4BE0), Color(0xFF3A2CB8), 'habit'),
      AwardKind.sessions50 => const AwardLook(Icons.workspace_premium_outlined, Color(0xFF4A3BD0), Color(0xFF2E22A0), 'habit'),
      AwardKind.streak3 => const AwardLook(Icons.whatshot_outlined, Color(0xFFE5744C), Color(0xFFB24328), 'fire'),
      AwardKind.firstRun => const AwardLook(Icons.directions_run_outlined, Color(0xFF2E9FD9), Color(0xFF1B6FA8), 'start'),
      AwardKind.firstWalk => const AwardLook(Icons.hiking_outlined, Color(0xFF2E9FD9), Color(0xFF1B6FA8), 'start'),
      AwardKind.firstBike => const AwardLook(Icons.directions_bike_outlined, Color(0xFF2E9FD9), Color(0xFF1B6FA8), 'start'),
      AwardKind.recordKm => const AwardLook(Icons.shield_outlined, Color(0xFFE2574C), Color(0xFFA83228), 'best', round: false),
      AwardKind.recordSteps => const AwardLook(Icons.shield_outlined, Color(0xFFE2574C), Color(0xFFA83228), 'best', round: false),
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
/// one short tap for a first, a stamping pair for milestones, a long
/// drumroll for broken records and the grandest totals.
List<Duration> cheerRhythm(AwardKind k) => switch (k) {
      AwardKind.first ||
      AwardKind.firstRun ||
      AwardKind.firstWalk ||
      AwardKind.firstBike => const [Duration(milliseconds: 300)],
      AwardKind.km2 ||
      AwardKind.km5 ||
      AwardKind.km10 ||
      AwardKind.km50 ||
      AwardKind.session5 ||
      AwardKind.minutes30 ||
      AwardKind.minutes60 ||
      AwardKind.sessions5 ||
      AwardKind.sessions10 ||
      AwardKind.streak3 => const [Duration(milliseconds: 220), Duration(milliseconds: 220), Duration(milliseconds: 220)],
      AwardKind.km21 ||
      AwardKind.km100 ||
      AwardKind.session10 ||
      AwardKind.steps5k => const [Duration(milliseconds: 260), Duration(milliseconds: 160), Duration(milliseconds: 260), Duration(milliseconds: 160), Duration(milliseconds: 260)],
      AwardKind.steps10k ||
      AwardKind.steps20k ||
      AwardKind.sessions25 => const [Duration(milliseconds: 140), Duration(milliseconds: 140), Duration(milliseconds: 140), Duration(milliseconds: 140), Duration(milliseconds: 140), Duration(milliseconds: 140)],
      AwardKind.km42 ||
      AwardKind.sessions50 ||
      AwardKind.recordKm ||
      AwardKind.recordSteps => const [Duration(milliseconds: 500), Duration(milliseconds: 200), Duration(milliseconds: 500), Duration(milliseconds: 200), Duration(milliseconds: 500)],
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
