import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/i18n/i18n.dart';
import '../../core/net/api.dart';
import '../../core/settings.dart' show AppSettings;
import '../../core/widgets/brand.dart';
import '../../core/widgets/flat.dart';
import '../health/health_screen.dart' show FlutterMapSheetMap;
import '../photos/photo_share.dart';
import '../sos/contact_people.dart';
import '../sos/guardian_badges.dart';
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
/// Both states open on a photo of real people, and under the picker sits the share history:
/// every past share, when it ran and how many contacts saw it.
class ShareScreen extends StatefulWidget {
  const ShareScreen({super.key, required this.share, required this.api, required this.i18n, required this.people, this.settings});
  final ShareController share;
  final SentriApi api;
  final I18n i18n;
  final ContactPeople people;

  /// The person's choices, so the share story maps wear the base layer they chose
  /// on the map tab (satellite, hybrid, night...). Null in tests.
  final AppSettings? settings;

  @override
  State<ShareScreen> createState() => _ShareScreenState();
}

class _ShareScreenState extends State<ShareScreen> {
  late Future<List<ContactStatus>> _contacts = widget.api.listContacts();
  late Future<List<ShareRecord>> _history = widget.api.shareHistory();
  final Set<String> _picked = {};
  double _hours = 8;
  bool _busy = false;
  String? _error;
  double _scrollOffset = 0;
  bool _entered = false;
  // The same names and guardian characters the Emergency-contacts screen manages:
  // one store, so every change made there shows up here too.
  Map<String, Person> _people = const {};

  @override
  void initState() {
    super.initState();
    unawaited(_loadPeople());
    // Read the history once; a share started from this screen adds itself on its own refresh.
    unawaited(_history.then((h) {
      if (mounted) setState(() => _entered = true);
    }).catchError((_) {
      if (mounted) setState(() => _entered = true);
    }));
  }

  Future<void> _loadPeople() async {
    final p = await widget.people.load();
    if (mounted) setState(() => _people = p);
  }

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
    if (r == ShareStartOutcome.started) {
      unawaited(_history = widget.api.shareHistory().then((v) {
        if (mounted) setState(() {});
        return v;
      }));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.share, widget.i18n]),
      builder: (context, _) => widget.share.active != null ? _sharing(context, widget.share.active!) : _picker(context),
    );
  }

  // ---------------------------------------------------------------- before

  Widget _banner(BuildContext context) {
    // The photo gently slides as the page scrolls (parallax), and rises softly the
    // first time the screen opens.
    final shift = (-_scrollOffset * 0.35).clamp(-60.0, 60.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: SizedBox(
        height: 150,
        width: double.infinity,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Transform.translate(
              offset: Offset(0, shift),
              child: Image.memory(photoShareBytes, fit: BoxFit.cover, gaplessPlayback: true),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Color(0x66000000), Color(0x00000000)],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _picker(BuildContext context) {
    return FlatPage(
      physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
      onScroll: (p) => setState(() => _scrollOffset = p),
      title: t('share.title'),
      subtitle: t('share.help'),
      footer: Column(mainAxisSize: MainAxisSize.min, children: [
        if (widget.share.stopPending) _note(t('share.stop_pending')),
        if (_error != null) _note(_error!, error: true),
        PillButton(label: t('share.start'), onPressed: _picked.isEmpty || _busy ? null : () => unawaited(_start())),
      ]),
      children: [
        AnimatedSlide(
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
          offset: _entered ? Offset.zero : const Offset(0, 0.12),
          child: Opacity(
            opacity: _entered ? 1 : 0,
            child: _banner(context),
          ),
        ),
        const SizedBox(height: 8),
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
        const SizedBox(height: 24),
        _historySection(context),
      ],
    );
  }

  Widget _historySection(BuildContext context) {
    return FutureBuilder<List<ShareRecord>>(
      future: _history,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(padding: EdgeInsets.only(top: 4, bottom: 20), child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))));
        }
        if (snap.hasError) return const SizedBox.shrink();
        final items = snap.data ?? const <ShareRecord>[];
        if (items.isEmpty) {
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t('exercise.history'), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Flat.muted(context))),
            const SizedBox(height: 8),
            FlatGroup(children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                child: Text(t('pins.must_differ'), style: TextStyle(fontSize: 13.5, height: 1.4, color: Flat.muted(context))),
              ),
            ]),
          ]);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t('exercise.history'), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Flat.muted(context))),
          const SizedBox(height: 8),
          FlatGroup(header: null, children: [
            for (final r in items.take(15))
              InkWell(
                // One tap opens the story of the share: when it ran, who saw it,
                // and the line the phone recorded - where the person passed.
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => _ShareDetailScreen(
                    i18n: widget.i18n,
                    record: r,
                    track: widget.share.trackPoints(r.id),
                    mapType: widget.settings?.mapType ?? 'standard',
                  ),
                )),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                  child: Row(children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0x1A1FA85B)),
                      child: const Icon(Icons.location_on_outlined, size: 17, color: Flat.live),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${clockTime(r.startedAt)} – ${clockTime(r.endedAt)}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                        Text(
                          t('share.people', {'n': r.recipients.toString()}),
                          style: TextStyle(fontSize: 12.5, color: Flat.muted(context)),
                        ),
                      ]),
                    ),
                    Icon(Icons.check_circle_outline, size: 18, color: Flat.muted(context)),
                    const SizedBox(width: 6),
                    Icon(Icons.chevron_right, size: 20, color: Flat.muted(context)),
                  ]),
                ),
              ),
          ]),
        ]);
      },
    );
  }

  Widget _note(String s, {bool error = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(s, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, height: 1.4, color: error ? Flat.danger : Flat.muted(context))),
      );

  Widget _row(BuildContext context, ContactStatus c) {
    final on = _picked.contains(c.id);
    final can = c.reachable && c.id.isNotEmpty;
    // The same face and name the person set in Emergency contacts: a friendly drawn
    // character when one was picked, the plain fallback circle otherwise.
    final person = _people[c.phone];
    final hasPerson = (person?.badge.isNotEmpty ?? false) || (person?.name.isNotEmpty ?? false);
    final display = person?.name.isNotEmpty == true ? person!.name : prettyPhone(c.phone);
    return InkWell(
      onTap: can ? () => setState(() => on ? _picked.remove(c.id) : _picked.add(c.id)) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(children: [
          hasPerson
              ? GuardianAvatar(badge: badgeById(person!.badge.isNotEmpty ? person.badge : guardianBadges.first.id), size: 46)
              : FlatAvatar(on: on),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(display, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: can ? null : Flat.muted(context))),
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
      physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
      onScroll: (p) => setState(() => _scrollOffset = p),
      title: t('share.title'),
      footer: Column(mainAxisSize: MainAxisSize.min, children: [
        FlatButton(label: t('share.extend'), quiet: true, onPressed: () => unawaited(widget.share.extend())),
        const SizedBox(height: 10),
        FlatButton(label: t('share.stop'), danger: true, onPressed: () => unawaited(widget.share.stop())),
      ]),
      children: [
        AnimatedSlide(
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
          offset: _entered ? Offset.zero : const Offset(0, 0.12),
          child: Opacity(
            opacity: _entered ? 1 : 0,
            child: _banner(context),
          ),
        ),
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

/// The story of one past share, the way a finished exercise session tells its
/// own: the clock window and who was watching, then the line the phone
/// recorded - where the person actually passed - fitted to the view with the
/// start and end pinned, Strava-style.
class _ShareDetailScreen extends StatelessWidget {
  const _ShareDetailScreen({required this.i18n, required this.record, required this.track, this.mapType = 'standard'});
  final I18n i18n;
  final ShareRecord record;
  final Future<List<List<double>>> track;

  /// The base layer chosen on the map tab.
  final String mapType;

  @override
  Widget build(BuildContext context) {
    final t = i18n.t;
    final r = record;
    final day = '${r.startedAt.day}/${r.startedAt.month}';
    return FlatPage(
      title: '${t('share.title')} · ${t('exercise.hist_on', {'d': day})}',
      children: [
        // The stat strip: the clock window and who could see it.
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            child: Column(children: [
              Text('${clockTime(r.startedAt)} – ${clockTime(r.endedAt)}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, height: 1.05, fontFeatures: [FontFeature.tabularFigures()])),
              const SizedBox(height: 4),
              Text(t('share.people', {'n': r.recipients.toString()}), style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Flat.muted(context))),
            ]),
          ),
        ),
        const SizedBox(height: 16),
        // The route, nearly full-bleed like the exercise detail: start green,
        // end indigo, over the line the person passed while sharing.
        ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: SizedBox(
            height: 280,
            child: FutureBuilder<List<List<double>>>(
              future: track,
              builder: (context, snap) {
                final pts = snap.data ?? const <List<double>>[];
                return FlutterMapSheetMap(
                  path: [for (final p in pts) LatLng(p[0], p[1])],
                  ends: true,
                  mapType: mapType,
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text(t('share.live_note'), textAlign: TextAlign.center, style: TextStyle(fontSize: 13, height: 1.45, color: Flat.muted(context))),
      ],
    );
  }
}
