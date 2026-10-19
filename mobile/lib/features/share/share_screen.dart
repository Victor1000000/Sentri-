import 'dart:async';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/i18n/i18n.dart';
import '../../core/net/api.dart';
import '../../core/widgets/brand.dart';
import '../../core/widgets/flat.dart';
import 'share_controller.dart';

String prettyPhone(String e164) {
  if (e164.startsWith('+234') && e164.length == 14) {
    final n = '0${e164.substring(4)}';
    return '${n.substring(0, 4)} ${n.substring(4, 7)} ${n.substring(7)}';
  }
  return e164;
}

String clockTime(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '$h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'am' : 'pm'}';
}

/// Share location. Before sharing: pick people and how long. While sharing: one calm status and one Stop.
class ShareScreen extends StatefulWidget {
  const ShareScreen({super.key, required this.share, required this.api, required this.i18n});
  final ShareController share;
  final SentriApi api;
  final I18n i18n;

  @override
  State<ShareScreen> createState() => _ShareScreenState();
}

class _ShareScreenState extends State<ShareScreen> {
  late Future<List<ContactStatus>> _contacts = widget.api.listContacts();
  final Set<String> _picked = {};
  double _hours = 8;
  bool _busy = false;
  String? _error;

  String t(String k, [Map<String, String> a = const {}]) => widget.i18n.t(k, a);

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final r = await widget.share.start(_picked.toList(), hours: _hours);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = switch (r) {
        ShareStartOutcome.started => null,
        ShareStartOutcome.noneReachable => t('share.none_reachable'),
        ShareStartOutcome.offline => t('share.offline'),
        ShareStartOutcome.failed => t('share.failed'),
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.share, widget.i18n]),
      builder: (context, _) => widget.share.active != null ? _sharing(context, widget.share.active!) : _picker(context),
    );
  }

  // ---------------------------------------------------------------- before

  Widget _picker(BuildContext context) {
    return FlatPage(
      title: t('share.title'),
      subtitle: t('share.help'),
      footer: Column(mainAxisSize: MainAxisSize.min, children: [
        if (widget.share.stopPending) _note(t('share.stop_pending')),
        if (_error != null) _note(_error!, error: true),
        PillButton(label: t('share.start'), onPressed: _picked.isEmpty || _busy ? null : () => unawaited(_start())),
      ]),
      children: [
        FutureBuilder<List<ContactStatus>>(
          future: _contacts,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) return const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()));
            if (snap.hasError) {
              return FlatGroup(children: [
                ListTile(
                  title: Text(t('contacts.load_failed')),
                  trailing: TextButton(onPressed: () => setState(() => _contacts = widget.api.listContacts()), child: Text(t('contacts.retry'))),
                ),
              ]);
            }
            final list = [for (final c in snap.data ?? const <ContactStatus>[]) if (c.consent != 'declined') c];
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              FlatGroup(header: t('share.with_label'), children: [for (final c in list) _row(context, c)]),
              const SizedBox(height: 24),
              Text(t('share.for'), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Flat.muted(context))),
              const SizedBox(height: 8),
              _durations(context),
              const SizedBox(height: 14),
              Text(t('share.limit_note'), style: TextStyle(fontSize: 13, height: 1.4, color: Flat.muted(context))),
            ]);
          },
        ),
      ],
    );
  }

  Widget _note(String s, {bool error = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(s, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, height: 1.4, color: error ? Flat.danger : Flat.muted(context))),
      );

  Widget _row(BuildContext context, ContactStatus c) {
    final on = _picked.contains(c.id);
    final can = c.reachable && c.id.isNotEmpty;
    return InkWell(
      onTap: can ? () => setState(() => on ? _picked.remove(c.id) : _picked.add(c.id)) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(children: [
          FlatAvatar(on: on),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(prettyPhone(c.phone), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: can ? null : Flat.muted(context))),
              const SizedBox(height: 2),
              Text(can ? t('contacts.on_sentri') : t('share.not_on_sentri'), style: TextStyle(fontSize: 13, color: Flat.muted(context))),
            ]),
          ),
          if (can)
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 26,
              height: 26,
              decoration: BoxDecoration(shape: BoxShape.circle, color: on ? Brand.indigo : Colors.transparent, border: Border.all(color: on ? Brand.indigo : Flat.muted(context), width: 1.6)),
              child: on ? const Icon(Icons.check, size: 16, color: Colors.white) : null,
            )
          else
            TextButton(onPressed: () => unawaited(Share.share(t('share.invite_text'))), child: Text(t('share.invite'))),
        ]),
      ),
    );
  }

  Widget _durations(BuildContext context) {
    const options = [1.0, 4.0, 8.0, 24.0];
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: Flat.hairline(context), borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        for (final h in options)
          Expanded(
            child: Semantics(
              button: true,
              selected: _hours == h,
              child: GestureDetector(
                onTap: () => setState(() => _hours = h),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: _hours == h ? Flat.card(context) : Colors.transparent, borderRadius: BorderRadius.circular(10)),
                  child: Text(t('share.hours', {'n': h.toInt().toString()}), style: TextStyle(fontSize: 14, fontWeight: _hours == h ? FontWeight.w600 : FontWeight.w500)),
                ),
              ),
            ),
          ),
      ]),
    );
  }

  // ---------------------------------------------------------------- while sharing

  Widget _sharing(BuildContext context, ShareInfo s) {
    return FlatPage(
      title: t('share.title'),
      footer: Column(mainAxisSize: MainAxisSize.min, children: [
        FlatButton(label: t('share.extend'), quiet: true, onPressed: () => unawaited(widget.share.extend())),
        const SizedBox(height: 10),
        FlatButton(label: t('share.stop'), danger: true, onPressed: () => unawaited(widget.share.stop())),
      ]),
      children: [
        const SizedBox(height: 28),
        Center(
          child: Column(children: [
            const LiveDot(size: 22),
            const SizedBox(height: 18),
            Text(t('share.sharing'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: -0.4)),
            const SizedBox(height: 8),
            Text(t('share.until', {'t': clockTime(s.expiresAt)}), style: TextStyle(fontSize: 16, color: Flat.muted(context))),
            if (s.contactIds.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(t('share.people', {'n': s.contactIds.length.toString()}), style: TextStyle(fontSize: 16, color: Flat.muted(context))),
            ],
          ]),
        ),
        const SizedBox(height: 36),
        Text(t('share.live_note'), textAlign: TextAlign.center, style: TextStyle(fontSize: 13, height: 1.45, color: Flat.muted(context))),
      ],
    );
  }
}
