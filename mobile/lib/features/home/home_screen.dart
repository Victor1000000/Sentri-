import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/i18n/i18n.dart';
import '../../core/emergency.dart';
import '../../core/profile.dart';
import '../../core/widgets/brand.dart';
import '../../core/platform/native_bridge.dart';
import '../../core/settings.dart';
import '../../core/net/api.dart';
import '../contacts/contacts_screen.dart';
import '../devices/watch_screen.dart';
import '../health/exercise_controller.dart';
import '../inbox/inbox_controller.dart';
import '../location/location.dart';
import '../police/police_directory.dart';
import '../inbox/inbox_screen.dart';
import '../share/share_controller.dart';
import '../share/share_screen.dart';
import '../location/travel_screen.dart';
import '../../core/widgets/flat.dart';
import '../../core/widgets/avatar_icons.dart';
import '../onboarding/floating3d.dart';
import '../../core/widgets/glass.dart';
import '../checkin/checkin_controller.dart';
import '../onboarding/permissions_panel.dart';
import '../sos/pin_pad.dart';
import '../sos/contact_people.dart';
import '../sos/sos_controller.dart';

/// The face the home screen wears: a big mood face on a full-bleed colour field.
/// Safe: a calm field of green, closed-shape smiley — the same language as the
/// reference the app was shown: green smiling face = you are covered. While the
/// person holds the SOS — or the alert is live — the whole screen leans toward
/// alarm red and the face smirks, not frowns. The face blinks every two seconds
/// so it feels alive; the shared painter lives in flat.dart.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.sos, required this.settings, required this.i18n, required this.bridge, required this.api, required this.inbox, required this.share, required this.checkin, required this.police, required this.people, required this.profile, required this.exercise, required this.location});
  final SentriApi api;
  final InboxController inbox;
  final ShareController share;
  final CheckInController checkin;
  final Future<PoliceDirectory> police;
  final SosController sos;
  final AppSettings settings;
  final I18n i18n;
  final NativeBridge bridge;
  final Profile profile;
  final ExerciseController exercise;
  final LocationSource location;

  /// Names and drawn characters for the emergency contacts.
  final ContactPeople people;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  late final AnimationController _hold = AnimationController(vsync: this, duration: const Duration(seconds: 1))
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        _hold.reset();
        unawaited(widget.sos.trigger('floating'));
      }
    });
  /// One blink every two seconds: the controller repeats each cycle, the eyes
  /// shut and reopen inside the first fifth of it. Motion-reduced phones keep
  /// the face still.
  late final AnimationController _blink = AnimationController(vsync: this, duration: const Duration(seconds: 2));
  int _titleTaps = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Flat.still(context)) {
      _blink.stop();
    } else if (!_blink.isAnimating) {
      _blink.repeat();
    }
  }

  /// How shut the eyes are this frame: nothing most of the cycle, one smooth
  /// blink at the top of it.
  double _blinkValue() {
    if (Flat.still(context)) return 0;
    final v = _blink.value;
    const blinkSpan = 0.22; // 440 ms of the 2 s cycle: close then open
    if (v >= blinkSpan) return 0;
    return math.sin(v / blinkSpan * math.pi);
  }

  @override
  void dispose() {
    _hold.dispose();
    _blink.dispose();
    super.dispose();
  }

  Future<void> _setTriggers(TriggerSettings t) async {
    await widget.settings.update(triggers: t);
    await widget.bridge.startProtection(t);
  }

  /// Five taps on the title opens a PIN pad. It is how the user ends a silent (duress) alert once
  /// they are safe: after a duress PIN the screen looks idle, so there is no visible "stop" button.
  Future<void> _hiddenPin() async {
    final pin = await showDialog<String>(
      context: context,
      builder: (ctx) => Dialog(child: Padding(padding: const EdgeInsets.all(16), child: PinPad(onSubmit: (p) => Navigator.pop(ctx, p)))),
    );
    if (pin != null) await widget.sos.submitPin(pin);
  }

  /// A time of day greeting, in the person's language: morning, afternoon, evening
  /// and night have their own words here.
  String _greetKey() {
    final h = DateTime.now().hour;
    if (h >= 5 && h < 12) return 'police.reported';
    if (h < 17) return 'police.unverified';
    if (h < 21) return 'police.to_confirm';
    return 'police.unconfirmed';
  }

  Future<void> _openProfile() async {
    final profile = widget.profile;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _ProfileSheet(profile: profile, api: widget.api, i18n: widget.i18n, exercise: widget.exercise),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.i18n.t;
    return ListenableBuilder(
      listenable: Listenable.merge([widget.settings, widget.i18n, widget.inbox, widget.share, widget.checkin, widget.profile, widget.sos]),
      builder: (context, _) {
        final s = widget.settings;
        final alarm = Theme.of(context).colorScheme.error;
        final muted = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6);
        /// The face reads red once the SOS is held — and stays red (with its
        /// smirk) for as long as the alert is live: countdown, active, contacts
        /// responding; only idle calms it back to green.
        final alarmOn = widget.sos.phase != SosPhase.idle;
        final greeting = t(_greetKey());
        final name = widget.profile.name;
        final faceHeight = (MediaQuery.of(context).size.height * 0.42).clamp(300.0, 430.0);
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: GlassBackdrop(child: SingleChildScrollView(
            // The bouncy pull pushes the whole mood field as one: the spring
            // keeps the home screen feeling alive, matching the other tabs.
            physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SentriTopBar(
                    i18n: widget.i18n,
                    compact: true,
                    // v41: the language sheet offers the languages of the country
                    // the person signed up with; their device region as fallback.
                    countryIso: countryByDial(dialCodeFromE164(widget.settings.lastPhone) ?? '')?.iso ?? countryForLocale(Platform.localeName)?.iso,
                    onLogoTap: () {
                      if (++_titleTaps >= 5) {
                        _titleTaps = 0;
                        unawaited(_hiddenPin());
                      }
                    },
                    onLanguage: (c) async {
                      await widget.i18n.setLanguage(c);
                      await s.update(language: c);
                    },
                  ),
                  // The person's own face and name greet them, like the flat reference:
                  // avatar left, greeting and name right.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 4, 22, 0),
                    child: Row(children: [
                      GestureDetector(
                        onTap: _openProfile,
                        child: _Avatar(profile: widget.profile, showEdit: true),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(greeting, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: muted)),
                          const SizedBox(height: 2),
                          Text(
                            // No name set yet: the bold line under the greeting
                            // is the protection state itself - confident, and
                            // it never wastes the space on a filler sentence.
                            name.isEmpty ? t('home.protected') : name,
                            // The greeting gets room: two lines instead of one
                            // clipped line, so the whole line always shows.
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 17.5, height: 1.18, fontWeight: FontWeight.w800, letterSpacing: -0.2),
                          ),
                        ]),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 22),
                    child: _MessageBar(
                      inbox: widget.inbox,
                      i18n: widget.i18n,
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => InboxScreen(inbox: widget.inbox, api: widget.api, i18n: widget.i18n, police: widget.police, settings: widget.settings))),
                    ),
                  ),
                  const SizedBox(height: 16),
                  // The mood face. Holding it anywhere is the SOS: the hold draws the
                  // screen toward alarm red and stirs the face, then triggers.
                  Semantics(
                    button: true,
                    label: 'SOS',
                    child: GestureDetector(
                      onTapDown: (_) => _hold.forward(),
                      onTapUp: (_) => _hold.reset(),
                      onTapCancel: _hold.reset,
                      child: AnimatedBuilder(
                        animation: Listenable.merge([_hold, _blink]),
                        builder: (context, _) {
                          // Red while holding or while the alert is live; the
                          // colour and face are recomputed every frame here so
                          // the hold animates smoothly.
                          final red = math.max(_hold.value, alarmOn ? 1.0 : 0.0);
                          final skin = Color.lerp(const Color(0xFF1E9E56), alarm, red)!;
                          const faceInk = Color(0xFF101B12);
                          final blinkV = _blinkValue();
                          return Container(
                          margin: const EdgeInsets.symmetric(horizontal: 22),
                          height: faceHeight,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(28),
                            color: skin,
                            boxShadow: [BoxShadow(color: skin.withValues(alpha: 0.35 + 0.25 * _hold.value), blurRadius: 30 + 30 * _hold.value, offset: const Offset(0, 12))],
                          ),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              // The 2D mood face, drawn by the shared painter —
                              // back from the 3D experiment, but now lit: a key
                              // light and shade give the card volume, the eyes
                              // carry shadows and glints, and the smile has
                              // depth. It still blinks every two seconds via
                              // [blinkV], and holding still stirs the card.
                              CustomPaint(
                                painter: MoodFacePainter(red, faceInk, blink: blinkV),
                              ),
                              Align(
                                alignment: Alignment.bottomCenter,
                                child: Padding(
                                  padding: const EdgeInsets.only(bottom: 18),
                                  child: Text(
                                    _hold.value > 0.05 ? t('home.hold') : t('home.protected'),
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800, letterSpacing: 0.2),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  ),
                  const SizedBox(height: 22),
                  // The home functions as circles, the way the flat reference
                  // boards draw them: icon in a card circle, its name right
                  // underneath. A green LiveDot rides the share circle while a
                  // share is running. v42 adds the fourth circle, Travel, right
                  // beside "Ways to call for help": the plane/train reading the
                  // app already makes during shares, with a screen of its own.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    // Each circle gets an equal quarter of the row, so long names
                    // like "Ways to call for help" wrap inside their own space
                    // instead of running off the screen edge.
                    child: Row(children: [
                      Expanded(
                        child: _CircleTile(
                          label: t('share.title'),
                          icon: Icons.share_location_rounded,
                          live: widget.share.active != null,
                          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ShareScreen(share: widget.share, api: widget.api, i18n: widget.i18n, people: widget.people, settings: widget.settings))),
                        ),
                      ),
                      Expanded(
                        child: _CircleTile(
                          label: t('contacts.title'),
                          icon: Icons.people_alt_rounded,
                          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ContactsScreen(api: widget.api, people: widget.people, i18n: widget.i18n))),
                        ),
                      ),
                      Expanded(
                        child: _CircleTile(
                          label: t('triggers.title'),
                          icon: Icons.campaign_rounded,
                          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _ShortcutsPage(home: this))),
                        ),
                      ),
                      Expanded(
                        child: _CircleTile(
                          label: t('travel.title'),
                          icon: Icons.flight_takeoff_rounded,
                          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TravelScreen(location: widget.location, i18n: widget.i18n))),
                        ),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          )),
        );
      },
    );
  }
}

/// The person's avatar on the home greeting: their chosen photo (or one of the
/// app's 50 drawn Sentri faces), with a pencil badge so it reads as editable —
/// the profile is one visible tap, not something hidden away.
class _Avatar extends StatelessWidget {
  const _Avatar({required this.profile, this.showEdit = false});
  final Profile profile;
  final bool showEdit;

  @override
  Widget build(BuildContext context) {
    // Whoever was chosen LAST wins: a picked icon beats an old photo and vice
    // versa (setAvatar/setIcon keep that flag right).
    final useIcon = profile.useIcon && profile.avatarIcon != null;
    final bytes = useIcon ? null : profile.avatar;
    final iconIdx = profile.avatarIcon;
    final name = profile.name;
    final letter = name.isNotEmpty ? name.characters.first.toUpperCase() : '?';
    Widget inner;
    if (bytes != null) {
      // v42: errorBuilder - corrupt or unreadable photo bytes fall back to the
      // letter avatar instead of taking the home screen's build down with them.
      inner = Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true, errorBuilder: (_, __, ___) {
        final fallbackLetter = name.isNotEmpty ? name.characters.first.toUpperCase() : '?';
        return Center(child: fallbackLetter != '?' ? Text(fallbackLetter, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)) : const Icon(Icons.person, size: 24));
      });
    } else if (iconIdx != null) {
      inner = SentriAvatar(index: iconIdx, size: 46);
    } else {
      inner = Center(child: letter != '?' ? Text(letter, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)) : const Icon(Icons.person, size: 24));
    }
    return SizedBox(
      width: 46,
      height: 46,
      child: Stack(clipBehavior: Clip.none, children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
            border: Border.all(color: Brand.indigoHi.withValues(alpha: 0.4), width: 1.5),
          ),
          clipBehavior: Clip.antiAlias,
          child: inner,
        ),
        if (showEdit)
          Positioned(
            right: -3,
            bottom: -3,
            child: Container(
              width: 19,
              height: 19,
              decoration: BoxDecoration(shape: BoxShape.circle, color: Brand.indigo, border: Border.all(color: Colors.white, width: 2)),
              child: const Icon(Icons.edit, size: 9, color: Colors.white),
            ),
          ),
      ]),
    );
  }
}

/// The person's own profile sheet: a photo from the gallery (stays on this phone)
/// and the name that alert texts use ("Ada needs you"). Saving the name also tries
/// the server; offline saves still stick on the phone.
class _ProfileSheet extends StatefulWidget {
  const _ProfileSheet({required this.profile, required this.api, required this.i18n, required this.exercise});
  final Profile profile;
  final SentriApi api;
  final I18n i18n;
  final ExerciseController exercise;
  @override
  State<_ProfileSheet> createState() => _ProfileSheetState();
}

class _ProfileSheetState extends State<_ProfileSheet> {
  late final TextEditingController _name = TextEditingController(text: widget.profile.name);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    // v42: setName now resolves as soon as the name is safe on the phone (the
    // server mirror runs in the background), and this whole path is wrapped: no
    // storage hiccup can ever leave the sheet stuck or take the app down. The
    // sheet always closes.
    try {
      await widget.profile.setName(_name.text, syncToServer: (n) => widget.api.saveProfile(name: n));
    } catch (_) {}
    if (mounted) {
      final nav = Navigator.of(context);
      if (nav.canPop()) nav.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.i18n.t;
    final cs = Theme.of(context).colorScheme;
    final muted = cs.onSurface.withValues(alpha: 0.55);
    final mq = MediaQuery.of(context);
    return ListenableBuilder(
      listenable: widget.profile,
      builder: (context, _) => Padding(
        padding: EdgeInsets.fromLTRB(22, 4, 22, 22 + mq.viewInsets.bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: mq.size.height * 0.78),
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const SizedBox(height: 8),
              // The pick, shown big: tap it for a gallery photo; the pencil
              // badge says this is where editing happens.
              Center(
                child: GestureDetector(
                  onTap: () async {
                    final bytes = await pickAvatarImage();
                    if (bytes != null) await widget.profile.setAvatar(bytes);
                  },
                  child: SizedBox(
                    width: 74,
                    height: 74,
                    child: Stack(clipBehavior: Clip.none, children: [
                      Center(
                        child: Transform.scale(
                          scale: 74 / 46,
                          child: _Avatar(profile: widget.profile),
                        ),
                      ),
                      Positioned(
                        right: -2,
                        bottom: -2,
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(shape: BoxShape.circle, color: Brand.indigo, border: Border.all(color: Colors.white, width: 2)),
                          child: const Icon(Icons.photo_library_outlined, size: 15, color: Colors.white),
                        ),
                      ),
                    ]),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Center(child: Text(t('health.heart_perm'), style: TextStyle(fontSize: 12, color: muted))),
              const SizedBox(height: 14),
              // The activity story: sessions per week for the last ten weeks, so the
              // person can watch their own consistency build up.
              _ConsistencyCard(exercise: widget.exercise, i18n: widget.i18n),
              const SizedBox(height: 16),
              TextField(
                controller: _name,
                maxLength: 40,
                decoration: InputDecoration(
                  labelText: t('health.allow'),
                  counterText: '',
                  filled: true,
                  fillColor: cs.onSurface.withValues(alpha: 0.05),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 18),
              // The app's own 50 Sentri faces: a tap swaps the photo for one of
              // them. The chosen one wears a ring.
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: EdgeInsets.zero,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 6, crossAxisSpacing: 10, mainAxisSpacing: 10),
                itemCount: SentriAvatarPainter.count,
                itemBuilder: (c, i) {
                  final selected = widget.profile.useIcon && widget.profile.avatarIcon == i;
                  return GestureDetector(
                    onTap: () => unawaited(widget.profile.setIcon(i)),
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: selected ? Brand.indigo : Colors.transparent, width: 2.5),
                      ),
                      padding: const EdgeInsets.all(2.5),
                      child: LayoutBuilder(builder: (c, box) => SentriAvatar(index: i, size: box.biggest.shortestSide)),
                    ),
                  );
                },
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46), backgroundColor: cs.primary),
                onPressed: _save,
                icon: const Icon(Icons.check, size: 20),
                label: Text(t('common.continue'), style: const TextStyle(fontSize: 15)),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The consistency graph, Strava's Progress in miniature: one bar per week for
/// the last ten weeks, tallest week tallest bar, with the person's totals under
/// it. Painted, not a chart package - nothing to add to the app's size.
class _ConsistencyCard extends StatelessWidget {
  const _ConsistencyCard({required this.exercise, required this.i18n});
  final ExerciseController exercise;
  final I18n i18n;

  @override
  Widget build(BuildContext context) {
    final t = i18n.t;
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final now = DateTime.now();
    // One bucket per week, oldest first; weeks start on Monday.
    final counts = List<int>.filled(10, 0);
    var km = 0.0;
    for (final r in exercise.history) {
      final start = r.start;
      final monday = DateTime(start.year, start.month, start.day - (start.weekday - 1));
      final weeksAgo = (DateTime(now.year, now.month, now.day).difference(DateTime(monday.year, monday.month, monday.day)).inDays / 7).floor();
      if (weeksAgo < 0 || weeksAgo >= 10) continue;
      counts[9 - weeksAgo]++;
      km += r.km;
    }
    final thisWeek = counts.isEmpty ? 0 : counts.last;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.onSurface.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.insights_outlined, size: 18, color: cs.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(t('profile.consistency'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: cs.primary.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(999)),
            child: Text(
              t('profile.week_now', {'n': '$thisWeek'}),
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: dark ? cs.primary.withValues(alpha: 0.95) : cs.primary),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        CustomPaint(
          size: const Size.fromHeight(96),
          painter: _ConsistencyBars(
            counts,
            bar: cs.primary,
            faint: cs.onSurface.withValues(alpha: 0.10),
          ),
        ),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(child: Text(t('profile.consistency_hint'), style: TextStyle(fontSize: 11.5, height: 1.35, color: cs.onSurface.withValues(alpha: 0.55)))),
          Text(
            '${exercise.history.length} · ${t('exercise.hist_total', {'n': km < 1 ? km.toStringAsFixed(2) : km.toStringAsFixed(1)})}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: cs.onSurface.withValues(alpha: 0.55)),
          ),
        ]),
      ]),
    );
  }
}

/// Ten bars, one per week. A week with sessions wears a full-height-scaled bar
/// with a rounded top; an empty week wears a faint stub, so the gaps are as
/// visible as the effort - that is what consistency looks like.
class _ConsistencyBars extends CustomPainter {
  const _ConsistencyBars(this.counts, {required this.bar, required this.faint});
  final List<int> counts;
  final Color bar;
  final Color faint;

  @override
  void paint(Canvas canvas, Size size) {
    if (counts.isEmpty) return;
    final max = counts.fold<int>(0, (a, b) => a > b ? a : b);
    final n = counts.length;
    final gap = 6.0;
    final barW = (size.width - gap * (n - 1)) / n;
    for (var i = 0; i < n; i++) {
      final x = i * (barW + gap);
      final c = counts[i];
      if (c <= 0) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(x, size.height - 5, barW, 5), const Radius.circular(3)),
          Paint()..color = faint,
        );
        continue;
      }
      final h = max <= 0 ? 0.0 : 8.0 + (size.height - 8.0) * c / max;
      final top = size.height - h;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x, top, barW, h), Radius.circular(barW / 2)),
        Paint()..color = bar,
      );
    }
  }

  @override
  bool shouldRepaint(_ConsistencyBars oldDelegate) =>
      oldDelegate.bar != bar || oldDelegate.faint != faint || oldDelegate.counts.length != counts.length;
}

/// Trigger switches and permissions, one tap away from the clean home screen.
class _ShortcutsPage extends StatelessWidget {
  const _ShortcutsPage({required this.home});
  final _HomeScreenState home;
  @override
  Widget build(BuildContext context) {
    final w = home.widget;
    final t = w.i18n.t;
    return ListenableBuilder(
      listenable: Listenable.merge([w.settings, w.i18n]),
      builder: (context, _) {
        final s = w.settings;
        final cs = Theme.of(context).colorScheme;
        final tr = s.triggers;
        return Scaffold(
          body: SentriBackground(
            child: SafeArea(
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                padding: const EdgeInsets.fromLTRB(26, 16, 26, 32),
                children: [
                  Row(children: [
                    IconButton.outlined(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.arrow_back)),
                    const SizedBox(width: 12),
                    Expanded(child: Text(t('triggers.title'), style: Theme.of(context).textTheme.headlineSmall)),
                  ]),
                  const SizedBox(height: 16),
                  Card(
                    child: Column(children: [
                      if (Platform.isAndroid) ...[
                        SwitchListTile(title: Text(t('triggers.volume')), value: tr.volume, onChanged: (v) => unawaited(home._setTriggers(tr.copyWith(volume: v)))),
                        SwitchListTile(
                          title: Text(t('triggers.power')),
                          subtitle: Text(t('triggers.power_note'), style: TextStyle(fontSize: 12, height: 1.3, color: cs.onSurface.withValues(alpha: 0.55))),
                          value: tr.power,
                          onChanged: (v) => unawaited(home._setTriggers(tr.copyWith(power: v))),
                        ),
                        // v44: the person picks their own press count, so the alert only
                        // goes off on the number of presses they chose.
                        if (tr.power)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(t('triggers.presses_hint'), style: TextStyle(fontSize: 12, height: 1.3, color: cs.onSurface.withValues(alpha: 0.55))),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  for (final n in const [3, 4, 5, 6])
                                    InkWell(
                                      borderRadius: BorderRadius.circular(20),
                                      onTap: () => unawaited(home._setTriggers(tr.copyWith(presses: n))),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                                        decoration: BoxDecoration(
                                          color: tr.presses == n ? cs.primary : cs.primary.withValues(alpha: 0.10),
                                          borderRadius: BorderRadius.circular(20),
                                        ),
                                        child: Text(
                                          t('triggers.presses').replaceFirst('{n}', '$n'),
                                          style: TextStyle(
                                            fontSize: 13.5,
                                            fontWeight: FontWeight.w800,
                                            color: tr.presses == n ? cs.onPrimary : cs.primary,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ]),
                          ),
                        SwitchListTile(title: Text(t('triggers.floating')), value: tr.floating, onChanged: (v) => unawaited(home._setTriggers(tr.copyWith(floating: v)))),
                      ],
                      SwitchListTile(title: Text(t('triggers.data_saver')), value: s.dataSaver, onChanged: (v) => unawaited(s.update(dataSaver: v))),
                    ]),
                  ),
                  const SizedBox(height: 16),
                  // v41: watches. A paired Wear OS watch mirrors the phone's
                  // notifications; this card opens the honest explanation and
                  // a test ping the person can see arrive on the wrist.
                  Card(
                    child: ListTile(
                      leading: Icon(Icons.watch_outlined, color: cs.primary),
                      title: Text(t('watch.card')),
                      subtitle: Text(t('watch.card_sub'), style: TextStyle(fontSize: 12, height: 1.3, color: cs.onSurface.withValues(alpha: 0.55))),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => WatchScreen(i18n: w.i18n))),
                    ),
                  ),
                  const SizedBox(height: 16),
                  PermissionsPanel(bridge: w.bridge, i18n: w.i18n),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// One home function as a circle with its name underneath: a solid card disc
/// with a hairline edge (the flat card language), the icon in brand indigo,
/// and a LiveDot badge top-right when something is running. Tapping it makes
/// the little disc hop and wiggle — excited — before opening the screen.
class _CircleTile extends StatelessWidget {
  const _CircleTile({required this.label, required this.icon, required this.onTap, this.live = false});
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool live;

  @override
  Widget build(BuildContext context) {
    return TapBounce(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Stack(clipBehavior: Clip.none, children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Flat.card(context),
                border: Border.all(color: Flat.hairline(context)),
              ),
              child: Icon(icon, size: 28, color: Brand.indigoHi),
            ),
            if (live)
              Positioned(
                right: 1,
                top: 1,
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: Flat.card(context)),
                  child: const LiveDot(size: 7),
                ),
              ),
          ]),
          const SizedBox(height: 8),
          Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, height: 1.25, fontWeight: FontWeight.w600, color: Flat.muted(context)),
          ),
        ]),
      ),
    );
  }
}

/// The message bar. Calm when there is nothing new; turns red and names the person when a live alert needs a response.
class _MessageBar extends StatelessWidget {
  const _MessageBar({required this.inbox, required this.i18n, required this.onTap});
  final InboxController inbox;
  final I18n i18n;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final t = i18n.t;
    final h = inbox.headline;
    final urgent = h != null && h.urgent && h.live;
    final n = inbox.unread;
    final accent = urgent ? Flat.danger : Brand.indigoHi;
    return Semantics(
      button: true,
      label: t('inbox.title'),
      child: Glass(
        radius: 16,
        tint: urgent ? Flat.danger : null,
        child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(shape: BoxShape.circle, color: accent.withValues(alpha: 0.14)),
                // The 3D bell — or the 3D siren when an emergency is live.
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Image.memory(urgent ? f3dsirenBytes : f3dbellBytes, fit: BoxFit.contain, filterQuality: FilterQuality.high),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  h?.text ?? (n > 0 ? t('inbox.new', {'n': '$n'}) : t('inbox.quiet')),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, height: 1.3, fontWeight: n > 0 ? FontWeight.w600 : FontWeight.w400, color: n > 0 ? null : Flat.muted(context)),
                ),
              ),
              if (n > 0)
                Container(
                  margin: const EdgeInsets.only(left: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(99)),
                  child: Text('$n', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white)),
                )
              else
                Icon(Icons.chevron_right, size: 20, color: Flat.muted(context)),
            ]),
          ),
        ),
      )),
    );
  }
}
