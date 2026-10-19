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
import '../onboarding/permissions_panel.dart';
import '../sos/pin_pad.dart';
import '../sos/sos_controller.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.sos, required this.settings, required this.i18n, required this.bridge, required this.api, required this.inbox, required this.share, required this.police});
  final SentriApi api;
  final InboxController inbox;
  final ShareController share;
  final Future<PoliceDirectory> police;
  final SosController sos;
  final AppSettings settings;
  final I18n i18n;
  final NativeBridge bridge;

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

  @override
  Widget build(BuildContext context) {
    final t = widget.i18n.t;
    return ListenableBuilder(
      listenable: Listenable.merge([widget.settings, widget.i18n, widget.inbox, widget.share]),
      builder: (context, _) {
        final s = widget.settings;
        final dark = Theme.of(context).brightness == Brightness.dark;
        final alarm = Theme.of(context).colorScheme.error;
        final muted = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6);
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: GlassBackdrop(child: SafeArea(
            child: Column(
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
                const SizedBox(height: 20),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: Theme.of(context).colorScheme.tertiary)),
                  const SizedBox(width: 8),
                  Text(t('home.protected'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                ]),
                Expanded(
                  child: Center(
                    child: SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
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
                                width: 220,
                                height: 220,
                                child: Stack(alignment: Alignment.center, children: [
                                  Container(
                                    width: 196 + 24 * _hold.value,
                                    height: 196 + 24 * _hold.value,
                                    decoration: BoxDecoration(shape: BoxShape.circle, color: alarm.withValues(alpha: 0.08 + 0.08 * _hold.value)),
                                  ),
                                  SizedBox(width: 214, height: 214, child: CircularProgressIndicator(value: _hold.value, strokeWidth: 5, color: alarm, backgroundColor: Colors.transparent)),
                                  Container(
                                    width: 170,
                                    height: 170,
                                    decoration: BoxDecoration(color: alarm, shape: BoxShape.circle, boxShadow: [BoxShadow(color: alarm.withValues(alpha: 0.3), blurRadius: 26, offset: const Offset(0, 10))]),
                                    alignment: Alignment.center,
                                    child: const Text('SOS', style: TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.w600, letterSpacing: 1)),
                                  ),
                                ]),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 18),
                        Text(t('home.hold'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 48),
                          child: Text(t('home.hold_help'), textAlign: TextAlign.center, style: TextStyle(fontSize: 13, height: 1.4, color: muted)),
                        ),
                      ]),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 0, 22, 14),
                  child: Glass(
                    radius: 18,
                    child: Column(children: [
                      _MenuRow(
                        label: t('share.title'),
                        trailing: widget.share.active != null ? const _SharingTag() : null,
                        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ShareScreen(share: widget.share, api: widget.api, i18n: widget.i18n))),
                      ),
                      const Divider(height: 0.5, thickness: 0.5, indent: 16),
                      _MenuRow(
                        label: t('contacts.title'),
                        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ContactsScreen(api: widget.api, i18n: widget.i18n))),
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
                      SwitchListTile(title: Text(t('triggers.shake')), value: tr.shake, onChanged: (v) => unawaited(home._setTriggers(tr.copyWith(shake: v)))),
                      if (Platform.isAndroid) ...[
                        SwitchListTile(title: Text(t('triggers.volume')), value: tr.volume, onChanged: (v) => unawaited(home._setTriggers(tr.copyWith(volume: v)))),
                        SwitchListTile(
                          title: Text(t('triggers.power')),
                          subtitle: Text(t('triggers.power_note')),
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
