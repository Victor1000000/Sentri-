import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../../core/i18n/i18n.dart';
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
import '../../core/widgets/glass.dart';
import '../checkin/checkin_controller.dart';
import '../onboarding/permissions_panel.dart';
import '../sos/pin_pad.dart';
import '../sos/contact_people.dart';
import '../sos/sos_controller.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.sos, required this.settings, required this.i18n, required this.bridge, required this.api, required this.inbox, required this.share, required this.checkin, required this.police, required this.people});
  final SentriApi api;
  final InboxController inbox;
  final ShareController share;
  final CheckInController checkin;
  final Future<PoliceDirectory> police;
  final SosController sos;
  final AppSettings settings;
  final I18n i18n;
  final NativeBridge bridge;

  /// Names and drawn characters for the emergency contacts.
  final ContactPeople people;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _hold = AnimationController(vsync: this, duration: const Duration(seconds: 1))
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        _hold.reset();
        unawaited(widget.sos.trigger('floating'));
      }
    });
  int _titleTaps = 0;

  @override
  void dispose() {
    _hold.dispose();
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

  /// The whole screen is one column that scrolls if a small phone needs it, so no part ever
  /// overlaps another. The SOS button stays where it is on normal screens.
  @override
  Widget build(BuildContext context) {
    final t = widget.i18n.t;
    return ListenableBuilder(
      listenable: Listenable.merge([widget.settings, widget.i18n, widget.inbox, widget.share, widget.checkin]),
      builder: (context, _) {
        final s = widget.settings;
        final alarm = Theme.of(context).colorScheme.error;
        final muted = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6);
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: GlassBackdrop(child: SingleChildScrollView(
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
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 10, 22, 0),
                    child: _MessageBar(
                      inbox: widget.inbox,
                      i18n: widget.i18n,
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => InboxScreen(inbox: widget.inbox, api: widget.api, i18n: widget.i18n, police: widget.police))),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 26),
                    child: Text(
                      t('home.hero'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 17.5, height: 1.35, fontWeight: FontWeight.w800, letterSpacing: -0.2),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: Theme.of(context).colorScheme.tertiary)),
                    const SizedBox(width: 8),
                    Text(t('home.protected'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                  ]),
                  const SizedBox(height: 22),
                  Semantics(
                    button: true,
                    label: 'SOS',
                    child: GestureDetector(
                      onTapDown: (_) => _hold.forward(),
                      onTapUp: (_) => _hold.reset(),
                      onTapCancel: _hold.reset,
                      child: AnimatedBuilder(
                        animation: _hold,
                        builder: (context, _) => SizedBox(
                          width: 214,
                          height: 214,
                          child: Stack(alignment: Alignment.center, children: [
                            Container(
                              width: 190 + 22 * _hold.value,
                              height: 190 + 22 * _hold.value,
                              decoration: BoxDecoration(shape: BoxShape.circle, color: alarm.withValues(alpha: 0.08 + 0.08 * _hold.value)),
                            ),
                            SizedBox(width: 210, height: 210, child: CircularProgressIndicator(value: _hold.value, strokeWidth: 5, color: alarm, backgroundColor: Colors.transparent)),
                            Container(
                              width: 166,
                              height: 166,
                              decoration: BoxDecoration(color: alarm, shape: BoxShape.circle, boxShadow: [BoxShadow(color: alarm.withValues(alpha: 0.3), blurRadius: 26, offset: const Offset(0, 10))]),
                              alignment: Alignment.center,
                              child: const Text('SOS', style: TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.w600, letterSpacing: 1)),
                            ),
                          ]),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(t('home.hold'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 44),
                    child: Text(t('home.hold_help'), textAlign: TextAlign.center, style: TextStyle(fontSize: 13, height: 1.4, color: muted)),
                  ),
                  const SizedBox(height: 18),
                  // "Check on me": a timed safety watch. Contacts get a full alert if the
                  // person has not marked themselves safe when the window ends.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 0, 22, 12),
                    child: CheckInCard(checkin: widget.checkin, sos: widget.sos, i18n: widget.i18n),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 0, 22, 16),
                    child: Glass(
                      radius: 18,
                      child: Column(children: [
                        _MenuRow(
                          label: t('share.title'),
                          trailing: widget.share.active != null ? const _SharingTag() : null,
                          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ShareScreen(share: widget.share, api: widget.api, i18n: widget.i18n, people: widget.people))),
                        ),
                        const Divider(height: 0.5, thickness: 0.5, indent: 16),
                        _MenuRow(
                          label: t('contacts.title'),
                          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ContactsScreen(api: widget.api, people: widget.people, i18n: widget.i18n))),
                        ),
                        const Divider(height: 0.5, thickness: 0.5, indent: 16),
                        _MenuRow(
                          label: t('triggers.title'),
                          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _ShortcutsPage(home: this))),
                        ),
                      ]),
                    ),
                  ),
                ],
              ),
            ),
          )),
        );
      },
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

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.label, required this.onTap, this.trailing});
  final String label;
  final Widget? trailing;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          child: Row(children: [
            Expanded(child: Text(label, style: const TextStyle(fontSize: 16))),
            if (trailing != null) ...[trailing!, const SizedBox(width: 6)],
            Icon(Icons.chevron_right, size: 20, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4)),
          ]),
        ),
      );
}


/// "Live" tag on the Share location row while a share is running.
class _SharingTag extends StatelessWidget {
  const _SharingTag();
  @override
  Widget build(BuildContext context) => const Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(width: 22, height: 22, child: LiveDot(size: 7)),
        SizedBox(width: 2),
        Text('Live', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Flat.live)),
      ]);
}

/// The "Check on me" card. Idle: one button opens the phone's time picker, so the person chooses
/// exactly when their contacts should check on them - tonight's walk, the bus ride, whatever.
/// Running: shows when the alert would go out and one big "I'm safe" button. Nothing here
/// overlaps: the whole home screen is a scrolling column and this card lays out top-down rows.
class CheckInCard extends StatefulWidget {
  const CheckInCard({super.key, required this.checkin, required this.sos, required this.i18n});
  final CheckInController checkin;
  final SosController sos;
  final I18n i18n;
  @override
  State<CheckInCard> createState() => _CheckInCardState();
}

class _CheckInCardState extends State<CheckInCard> {
  /// A picked wall-clock time becomes a window from now. A time already past today means
  /// tomorrow at that time, which is what a person means when they pick "10:15 PM" at 9:40 PM.
  Future<void> _pickTime() async {
    final now = DateTime.now();
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(minutes: 30))),
    );
    if (picked == null || !mounted) return;
    var start = DateTime(now.year, now.month, now.day, picked.hour, picked.minute);
    if (!start.isAfter(now)) start = start.add(const Duration(days: 1));
    await widget.checkin.start(start.difference(now));
  }

  @override
  Widget build(BuildContext context) {
    final checkin = widget.checkin;
    final t = widget.i18n.t;
    final cs = Theme.of(context).colorScheme;
    final muted = cs.onSurface.withValues(alpha: 0.55);
    return ListenableBuilder(
      listenable: checkin,
      builder: (context, _) {
        final running = checkin.running;
        return Glass(
          radius: 18,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(running ? Icons.timer : Icons.timer_outlined, size: 20, color: cs.primary),
                const SizedBox(width: 8),
                Expanded(child: Text(t('home.check_title'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
              ]),
              const SizedBox(height: 4),
              Text(
                running
                    ? t('home.check_until', {'time': TimeOfDay.fromDateTime(checkin.endsAt!).format(context)})
                    : t('home.check_sub'),
                style: TextStyle(fontSize: 12.5, height: 1.35, color: muted),
              ),
              const SizedBox(height: 8),
              if (running) ...[
                Row(children: [
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44), backgroundColor: cs.primary),
                      onPressed: () => unawaited(checkin.cancel()),
                      icon: const Icon(Icons.task_alt, size: 20),
                      label: Text(t('home.check_safe'), style: const TextStyle(fontSize: 15)),
                    ),
                  ),
                ]),
              ] else ...[
                Row(children: [
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44), backgroundColor: cs.primary),
                      onPressed: _pickTime,
                      icon: const Icon(Icons.schedule, size: 20),
                      label: Text(t('home.check_pick'), style: const TextStyle(fontSize: 15)),
                    ),
                  ),
                ]),
              ],
            ]),
          ),
        );
      },
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
                child: Icon(urgent ? Icons.warning_amber_rounded : (n > 0 ? Icons.notifications : Icons.notifications_none), size: 19, color: accent),
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
