import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/i18n/i18n.dart';
import '../../core/profile.dart';
import '../../core/widgets/brand.dart';
import '../../core/platform/native_bridge.dart';
import '../../core/settings.dart';
import '../../core/net/api.dart';
import '../contacts/contacts_screen.dart';
import '../inbox/inbox_controller.dart';
import '../police/police_directory.dart';
import '../inbox/inbox_screen.dart';
import '../share/share_controller.dart';
import '../share/share_screen.dart';
import '../../core/widgets/flat.dart';
import '../../core/widgets/avatar_icons.dart';
import '../../core/widgets/faces3d.dart';
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
  const HomeScreen({super.key, required this.sos, required this.settings, required this.i18n, required this.bridge, required this.api, required this.inbox, required this.share, required this.checkin, required this.police, required this.people, required this.profile});
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
      builder: (ctx) => _ProfileSheet(profile: profile, api: widget.api, i18n: widget.i18n),
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
                            name.isEmpty ? t('home.hero') : name,
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
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => InboxScreen(inbox: widget.inbox, api: widget.api, i18n: widget.i18n, police: widget.police))),
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
                              // The 3D mood face: the calm grin, and the happy
                              // squint crossfaded in for every blink, so the
                              // face still blinks — now in 3D. Holding stirs
                              // it: it leans back and shakes a little, like it
                              // just got startled.
                              Center(
                                child: Transform.rotate(
                                  angle: 0.08 * math.sin(_hold.value * math.pi * 3),
                                  child: Transform.scale(
                                    scale: (1.0 - 0.06 * blinkV + 0.05 * _hold.value),
                                    child: SizedBox(
                                      width: 240,
                                      height: 240,
                                      child: Stack(children: [
                                        Image.memory(f3faceOpenBytes, width: 240, height: 240, fit: BoxFit.contain, filterQuality: FilterQuality.high, gaplessPlayback: true),
                                        if (blinkV > 0)
                                          Opacity(opacity: blinkV, child: Image.memory(f3faceClosedBytes, width: 240, height: 240, fit: BoxFit.contain, filterQuality: FilterQuality.high, gaplessPlayback: true)),
                                      ]),
                                    ),
                                  ),
                                ),
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
                  // share is running.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 0, 22, 16),
                    // Each circle gets an equal third of the row, so long names
                    // like "Ways to call for help" wrap inside their own space
                    // instead of running off the screen edge.
                    child: Row(children: [
                      Expanded(
                        child: _CircleTile(
                          label: t('share.title'),
                          icon: Icons.share_location_rounded,
                          live: widget.share.active != null,
                          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ShareScreen(share: widget.share, api: widget.api, i18n: widget.i18n, people: widget.people))),
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
      inner = Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
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
  const _ProfileSheet({required this.profile, required this.api, required this.i18n});
  final Profile profile;
  final SentriApi api;
  final I18n i18n;
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
    await widget.profile.setName(_name.text, syncToServer: (n) => widget.api.saveProfile(name: n));
    if (mounted) Navigator.of(context).pop();
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
                        SwitchListTile(title: Text(t('triggers.floating')), value: tr.floating, onChanged: (v) => unawaited(home._setTriggers(tr.copyWith(floating: v)))),
                      ],
                      SwitchListTile(title: Text(t('triggers.data_saver')), value: s.dataSaver, onChanged: (v) => unawaited(s.update(dataSaver: v))),
                    ]),
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
