import 'dart:async';
import 'dart:typed_data' show Uint8List;
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config.dart';
import '../../core/i18n/i18n.dart';
import '../../core/net/api.dart';
import '../../core/widgets/brand.dart';
import '../../core/widgets/flat.dart';
import '../../core/widgets/glass.dart';
import '../onboarding/floating3d.dart';
import '../police/police_call_card.dart';
import '../police/police_directory.dart';
import '../share/share_screen.dart';
import '../push/push_service.dart';
import 'inbox_controller.dart';

String _ago(DateTime d, String Function(String, [Map<String, String>]) t) {
  final m = DateTime.now().difference(d).inMinutes;
  if (m < 1) return t('inbox.now');
  if (m < 60) return t('inbox.min', {'n': '$m'});
  if (m < 1440) return t('inbox.hr', {'n': '${m ~/ 60}'});
  return t('inbox.day', {'n': '${m ~/ 1440}'});
}

/// Which art wears the message disc: a 3D render when we have one that fits,
/// an icon on a coloured disc otherwise. Each kind also carries its own
/// complementary accent, so the list reads as a colourful feed, not grey rows.
({Uint8List? img, IconData? icon, Color a, Color b, Color wash}) _art(InboxEntry e, bool urgent) => switch (e.kind) {
      'sos' || 'duress' || 'offline' => (
        img: urgent ? f3dsirenBytes : f3dbellBytes,
        icon: null,
        a: urgent ? const Color(0xFFFF6B5E) : const Color(0xFFFF8A65),
        b: urgent ? const Color(0xFFB3251B) : const Color(0xFFC2412F),
        wash: urgent ? const Color(0xFFB3251B) : const Color(0xFF7B6CF0),
      ),
      'low_battery' => (
        img: null,
        icon: Icons.battery_alert,
        a: const Color(0xFFFFC64D),
        b: const Color(0xFFE5A33C),
        wash: const Color(0xFFE5A33C),
      ),
      'health_alert' => (
        img: null,
        icon: Icons.monitor_heart_outlined,
        a: const Color(0xFF4CD6A8),
        b: const Color(0xFF1E9E56),
        wash: const Color(0xFF1E9E56),
      ),
      'share_start' || 'share_stop' => (
        img: f3dpinBytes,
        icon: null,
        a: const Color(0xFFFF7BAC),
        b: const Color(0xFFD6336C),
        wash: const Color(0xFFD6336C),
      ),
      _ => (
        img: f3dbellBytes,
        icon: null,
        a: const Color(0xFF9C8FF5),
        b: const Color(0xFF5348C8),
        wash: const Color(0xFF5348C8),
      ),
    };

/// Everything people sent you inside Sentri. Alerts only ever arrive here and as a push: never as a text.
class InboxScreen extends StatelessWidget {
  const InboxScreen({super.key, required this.inbox, required this.api, required this.i18n, required this.police});
  final Future<PoliceDirectory> police;
  final InboxController inbox;
  final SentriApi api;
  final I18n i18n;

  @override
  Widget build(BuildContext context) {
    final t = i18n.t;
    return ListenableBuilder(
      listenable: inbox,
      builder: (context, _) {
        final d = inbox.data;
        return FlatPage(
          title: t('inbox.title'),
          onRefresh: inbox.refresh,
          children: [
            if (d.invites.isNotEmpty) ...[
              FlatGroup(header: t('inbox.invites'), children: [
                for (final i in d.invites)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(t('inbox.invite_text', {'n': i.fromName ?? t('inbox.someone')}), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                      const SizedBox(height: 12),
                      Row(children: [
                        Expanded(child: FlatButton(label: t('inbox.decline'), quiet: true, danger: true, onPressed: () => unawaited(inbox.decide(i, accept: false)))),
                        const SizedBox(width: 10),
                        Expanded(child: FlatButton(label: t('inbox.accept'), onPressed: () => unawaited(inbox.decide(i, accept: true)))),
                      ]),
                    ]),
                  ),
              ]),
              const SizedBox(height: 22),
            ],
            if (d.items.isEmpty && !inbox.loading)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                // The empty mailbox wears the 3D bell, so even "nothing yet"
                // carries the app's character.
                child: Column(children: [
                  Image.memory(f3dbellBytes, width: 84, height: 84, filterQuality: FilterQuality.high),
                  const SizedBox(height: 12),
                  Text(inbox.failed ? (inbox.failedAuth ? t('inbox.need_signin') : t('inbox.failed')) : t('inbox.none'), textAlign: TextAlign.center, style: TextStyle(fontSize: 15, color: Flat.muted(context))),
                ]),
              )
            else
              // One rounded card per message, like the activity-feed reference:
              // roomy discs, a time chip, a live chip - sleek, not a flat list.
              Column(children: [for (final e in d.items) _tile(context, e)]),
            const SizedBox(height: 22),
            Text(t('inbox.scam_note'), style: TextStyle(fontSize: 13, height: 1.45, color: Flat.muted(context))),
            const SizedBox(height: 18),
            _TestAlertButton(api: api, i18n: i18n),
          ],
        );
      },
    );
  }

  Widget _tile(BuildContext context, InboxEntry e) {
    final urgent = e.urgent && e.live;
    final art = _art(e, urgent);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        // Unread messages carry a soft wash of their kind's accent, so the
        // feed reads colourful and new things pop.
        color: e.read ? null : art.wash.withValues(alpha: 0.08),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () async {
            await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AlertDetailScreen(entry: e, api: api, i18n: i18n, police: police)));
            unawaited(inbox.refresh());
          },
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              // The kind of message: a 3D render (siren, bell, pin) on a
              // colourful pastel disc, or its icon when no render fits.
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color.lerp(art.a, Colors.white, 0.25)!, art.b],
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: art.img != null
                      ? Image.memory(art.img!, fit: BoxFit.contain, filterQuality: FilterQuality.high)
                      : Icon(art.icon, size: 22, color: Colors.white),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(e.text, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, height: 1.35, fontWeight: e.read ? FontWeight.w400 : FontWeight.w600)),
                  const SizedBox(height: 7),
                  // The chip row: a live pill while the alert is running,
                  // otherwise the quiet time chip from the reference boards.
                  Row(children: [
                    if (e.live) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                        decoration: BoxDecoration(color: Flat.live.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(999)),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const LiveDot(size: 7),
                          const SizedBox(width: 5),
                          Text(i18n.t('inbox.live'), style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Flat.live)),
                        ]),
                      ),
                      const SizedBox(width: 6),
                    ],
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                      decoration: BoxDecoration(color: Flat.hairline(context), borderRadius: BorderRadius.circular(999)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.schedule, size: 12, color: Flat.muted(context)),
                        const SizedBox(width: 4),
                        Text(_ago(e.at, i18n.t), style: TextStyle(fontSize: 11.5, color: Flat.muted(context), fontFeatures: const [FontFeature.tabularFigures()])),
                      ]),
                    ),
                  ]),
                ]),
              ),
              if (!e.read) ...[
                const SizedBox(width: 8),
                Container(width: 9, height: 9, decoration: const BoxDecoration(shape: BoxShape.circle, color: Brand.indigoHi)),
              ] else ...[
                const SizedBox(width: 8),
                Icon(Icons.check_circle_outline, size: 18, color: Flat.muted(context)),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

class _TestAlertButton extends StatefulWidget {
  const _TestAlertButton({required this.api, required this.i18n});
  final SentriApi api;
  final I18n i18n;
  @override
  State<_TestAlertButton> createState() => _TestAlertButtonState();
}

class _TestAlertButtonState extends State<_TestAlertButton> {
  String? _msg;
  bool _busy = false;

  Future<void> _send() async {
    final t = widget.i18n.t;
    setState(() => _busy = true);
    String m;
    try {
      final r = await widget.api.sendTestAlert();
      m = r.reachable == 0 ? t('inbox.test_none') : t('inbox.test_sent', {'n': '${r.reachable}'});
    } on ApiHttpError catch (e) {
      m = e.status == 429 ? t('inbox.test_wait') : t('common.error');
    } catch (_) {
      m = t('common.error');
    }
    if (mounted) setState(() {
      _busy = false;
      _msg = m;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      FlatButton(label: widget.i18n.t('inbox.test_btn'), quiet: true, onPressed: _busy ? null : () => unawaited(_send())),
      if (_msg != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_msg!, style: TextStyle(fontSize: 13, color: Flat.muted(context)))),
    ]);
  }
}

/// One message. For a live alert or share it shows the map and refreshes the position.
class AlertDetailScreen extends StatefulWidget {
  const AlertDetailScreen({super.key, required this.entry, required this.api, required this.i18n, required this.police});
  final Future<PoliceDirectory> police;
  final InboxEntry entry;
  final SentriApi api;
  final I18n i18n;
  @override
  State<AlertDetailScreen> createState() => _AlertDetailScreenState();
}

class _AlertDetailScreenState extends State<AlertDetailScreen> {
  InboxDetail? _d;
  Timer? _poll;
  bool _missing = false;
  String? _responded;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _poll = Timer.periodic(const Duration(seconds: 10), (_) => unawaited(_load()));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await widget.api.inboxItem(widget.entry.id);
      if (!mounted) return;
      setState(() {
        _d = d;
        _missing = d == null;
      });
      if (d != null && d.state == 'ended') _poll?.cancel();
    } catch (_) {}
  }

  Future<void> _respond() async {
    try {
      final r = await widget.api.respondToAlert(widget.entry.id);
      unawaited(cancelAlertNotification(widget.entry.id)); // stops the ringing on this phone
      if (mounted) setState(() => _responded = r);
      unawaited(_load());
    } catch (_) {
      if (mounted) setState(() => _responded = 'error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.i18n.t;
    final d = _d;
    final e = d?.entry ?? widget.entry;
    final live = d != null && d.state != 'ended';
    final urgent = e.urgent && live;
    return FlatPage(
      title: e.from ?? t('inbox.someone'),
      children: [
        Glass(
          radius: 16,
          padding: const EdgeInsets.all(16),
          tint: urgent ? Flat.danger : null,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              if (live) const LiveDot(size: 8, color: Flat.live) else Icon(Icons.check_circle_outline, size: 18, color: Flat.muted(context)),
              const SizedBox(width: 6),
              Text(
                _missing ? t('inbox.gone') : (live ? (d.state == 'responding' ? t('inbox.responding') : t('inbox.live')) : t('inbox.ended')),
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: live ? Flat.live : Flat.muted(context)),
              ),
            ]),
            const SizedBox(height: 10),
            Text(e.text, style: const TextStyle(fontSize: 18, height: 1.35, fontWeight: FontWeight.w600)),
          ]),
        ),
        if (d != null && d.lat != null && d.lon != null) ...[
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              height: 240,
              child: FlutterMap(
                key: ValueKey('${d.lat},${d.lon}'),
                options: MapOptions(initialCenter: LatLng(d.lat!, d.lon!), initialZoom: 16, interactionOptions: const InteractionOptions(flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag)),
                children: [
                  TileLayer(urlTemplate: AppConfig.tileUrl, userAgentPackageName: 'ng.sentri.sentri'),
                  MarkerLayer(markers: [Marker(point: LatLng(d.lat!, d.lon!), width: 28, height: 28, child: Container(decoration: BoxDecoration(shape: BoxShape.circle, color: urgent ? Flat.danger : Brand.indigo, border: Border.all(color: Colors.white, width: 3))))]),
                ],
              ),
            ),
          ),
          if (d.geoAt != null) Padding(padding: const EdgeInsets.only(top: 8, left: 4), child: Text(t('inbox.updated', {'t': clockTime(d.geoAt!)}), style: TextStyle(fontSize: 13, color: Flat.muted(context)))),
        ],
        if (d != null && urgent) ...[
          const SizedBox(height: 16),
          PoliceCallCard(directory: widget.police, i18n: widget.i18n, lat: d.lat, lon: d.lon, forContact: true),
        ],
        if (d != null && d.canRespond) ...[
          const SizedBox(height: 20),
          FlatButton(label: _responded == 'ok' || d.state == 'responding' ? t('inbox.responding') : t('inbox.respond'), onPressed: d.state == 'responding' || _responded == 'ok' ? null : () => unawaited(_respond())),
        ],
        if (d?.callPhone != null) ...[
          const SizedBox(height: 10),
          FlatButton(label: t('inbox.call'), quiet: true, onPressed: () => unawaited(launchUrl(Uri(scheme: 'tel', path: d!.callPhone)))),
        ],
      ],
    );
  }
}
