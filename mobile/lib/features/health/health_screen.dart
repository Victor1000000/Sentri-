import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/i18n/i18n.dart';
import '../../core/widgets/flat.dart';
import 'health_controller.dart';

/// The Health tab: honest heart-rate readings from Health Connect, drink-water reminders at
/// the person's own pace, and hospitals near them - nearest first, with a call button. The
/// same calm card look as the rest of the app: big number, plain words, nothing loud.
class HealthScreen extends StatefulWidget {
  const HealthScreen({super.key, required this.health, required this.i18n});
  final HealthController health;
  final I18n i18n;

  @override
  State<HealthScreen> createState() => _HealthScreenState();
}

class _HealthScreenState extends State<HealthScreen> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.health.loadHospitals());
  }

  String t(String k, [Map<String, String>? a]) => widget.i18n.t(k, a);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: widget.health,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: Text(t('tabs.health'))),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            _section('HEART', t('health.heart'), Icons.favorite_border),
            _heartCard(context, cs),
            const SizedBox(height: 20),
            _section('WATER', t('health.water'), Icons.water_drop_outlined),
            _waterCard(context),
            const SizedBox(height: 20),
            _section('NEARBY', t('health.hospitals'), Icons.local_hospital_outlined),
            _hospitalsCard(context, cs),
          ],
        ),
      ),
    );
  }

  Widget _section(String note, String title, IconData icon) => Padding(
        padding: const EdgeInsets.only(left: 2, bottom: 8),
        child: Row(children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: -0.3)),
        ]),
      );

  // ---------------------------------------------------------------- heart

  Widget _heartCard(BuildContext context, ColorScheme cs) {
    final h = widget.health;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (h.connected == null) ...[
            const LinearProgressIndicator(minHeight: 2),
            const SizedBox(height: 8),
          ] else if (h.bpm != null) ...[
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('${h.bpm}', style: const TextStyle(fontSize: 46, fontWeight: FontWeight.w800, height: 1)),
              const SizedBox(width: 8),
              Padding(padding: const EdgeInsets.only(bottom: 7), child: Text('bpm', style: TextStyle(fontSize: 14, color: Flat.muted(context), fontWeight: FontWeight.w600))),
              const Spacer(),
              Icon(Icons.monitor_heart_outlined, size: 22, color: cs.primary),
            ]),
            const SizedBox(height: 6),
            if (h.baseline != null) Text(t('health.heart_base', {'n': '${h.baseline}'}), style: TextStyle(fontSize: 13.5, color: Flat.muted(context))),
            const SizedBox(height: 4),
            Text(t('health.heart_watch'), style: const TextStyle(fontSize: 13, height: 1.4)),
          ] else ...[
            Text(
              h.connected == false ? t('health.heart_none') : t('health.heart_perm'),
              style: const TextStyle(fontSize: 14, height: 1.45),
            ),
            if (h.connected == true) ...[
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 22)),
                  onPressed: () => unawaited(h.authorize()),
                  child: Text(t('health.allow')),
                ),
              ),
            ],
          ],
        ]),
      ),
    );
  }

  // ---------------------------------------------------------------- water

  Widget _waterCard(BuildContext context) {
    final s = widget.health.settings;
    const options = [0, 30, 60, 120, 180];
    String label(int m) => switch (m) {
          0 => t('health.water_off'),
          30 => t('health.water_30'),
          60 => t('health.water_1'),
          120 => t('health.water_2'),
          _ => t('health.water_3'),
        };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t('health.water_sub'), style: const TextStyle(fontSize: 14, height: 1.45)),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(color: Flat.hairline(context), borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              for (final m in options)
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: s.waterMinutes == m,
                    child: GestureDetector(
                      onTap: () => unawaited(s.update(waterMinutes: m)),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        height: 38,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: s.waterMinutes == m ? Flat.card(context) : Colors.transparent, borderRadius: BorderRadius.circular(10)),
                        child: Text(label(m), style: TextStyle(fontSize: 12.5, fontWeight: s.waterMinutes == m ? FontWeight.w600 : FontWeight.w500)),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
        ]),
      ),
    );
  }

  // ------------------------------------------------------------ hospitals

  Widget _hospitalsCard(BuildContext context, ColorScheme cs) {
    final h = widget.health;
    final list = h.hospitals;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(children: [
          if (h.hospitalsLoading) ...[
            Padding(padding: const EdgeInsets.all(28), child: LinearProgressIndicator(minHeight: 2, color: cs.primary)),
          ] else if (h.hospitalsFailed && list.isEmpty) ...[
            Padding(padding: const EdgeInsets.all(16), child: Text(t('health.hosp_error'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, height: 1.45))),
          ] else if (list.isEmpty) ...[
            Padding(padding: const EdgeInsets.all(16), child: Text(t('health.hosp_none'), textAlign: TextAlign.center, style: TextStyle(fontSize: 14, height: 1.45, color: Flat.muted(context)))),
          ] else
            for (var i = 0; i < list.length; i++) ...[
              if (i > 0) Divider(height: 1, color: Flat.hairline(context)),
              _hospitalTile(context, list[i], cs),
            ],
        ]),
      ),
    );
  }

  Widget _hospitalTile(BuildContext context, NearbyHospital p, ColorScheme cs) {
    final phone = p.phone;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(p.name, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
        const SizedBox(height: 3),
        Text(
          phone == null ? t('health.hosp_no_phone') : '${t('health.hosp_km', {'n': p.km < 10 ? p.km.toStringAsFixed(1) : p.km.round().toString()})} · $phone',
          style: TextStyle(fontSize: 13, color: phone == null ? cs.error.withValues(alpha: 0.7) : Flat.muted(context), fontFeatures: const [FontFeature.tabularFigures()]),
        ),
        if (phone != null) ...[
          const SizedBox(height: 9),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 40),
                padding: const EdgeInsets.symmetric(horizontal: 18),
                side: BorderSide(color: cs.primary),
                foregroundColor: cs.primary,
              ),
              onPressed: () => unawaited(_call(phone)),
              icon: const Icon(Icons.call_outlined, size: 18),
              label: Text(t('health.call'), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ]),
    );
  }

  Future<void> _call(String phone) async {
    final clean = phone.replaceAll(RegExp(r'[^0-9+*#]'), '');
    if (clean.isEmpty) return;
    try {
      await launchUrl(Uri(scheme: 'tel', path: clean), mode: LaunchMode.externalApplication);
    } catch (_) {
      // No dialler on this device: nothing to do; the number is still visible and copyable.
    }
  }
}
