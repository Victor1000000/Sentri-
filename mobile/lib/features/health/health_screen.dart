import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:camera/camera.dart' show CameraController, CameraPreview;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/i18n/i18n.dart';
import '../../core/widgets/flat.dart';
import 'health_controller.dart';

/// The Health tab: heart-rate readings taken by the app itself - fingertip over the
/// front camera, lit by the screen - plus a passive read of Health Connect when a band
/// or health app is feeding it, drink-water reminders at the person's own pace, and
/// hospitals near them - nearest first, with a call button. The same calm card look as
/// the rest of the app: big number, plain words, nothing loud.
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
    // Re-arms the water reminder on every open and refreshes hospitals when they are stale.
    unawaited(widget.health.onHealthTabOpen());
  }

  String t(String k, [Map<String, String> a = const {}]) => widget.i18n.t(k, a);

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
          if (h.measuring) ...[
            _measureArea(context, cs),
          ] else ...[
            // The measure flow is the primary path; no "connect a health app" homework.
            // A saved reading (from the camera or a band via Health Connect) still shows.
            if (h.bpm != null) ...[
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('${h.bpm}', style: const TextStyle(fontSize: 46, fontWeight: FontWeight.w800, height: 1)),
                const SizedBox(width: 8),
                Padding(padding: const EdgeInsets.only(bottom: 7), child: Text('bpm', style: TextStyle(fontSize: 14, color: Flat.muted(context), fontWeight: FontWeight.w600))),
                const Spacer(),
                Icon(Icons.monitor_heart_outlined, size: 22, color: cs.primary),
              ]),
              if (h.baseline != null) ...[
                const SizedBox(height: 6),
                Text(t('health.heart_base', {'n': '${h.baseline}'}), style: TextStyle(fontSize: 13.5, color: Flat.muted(context))),
              ],
              const SizedBox(height: 4),
              Text(t('health.heart_watch'), style: const TextStyle(fontSize: 13, height: 1.4)),
            ] else ...[
              Text(t('health.heart_cam'), style: const TextStyle(fontSize: 14, height: 1.45)),
            ],
            // Honest failure notes, each with its own advice.
            if (h.measureFailed && h.noCamera) ...[
              const SizedBox(height: 12),
              Text(t('health.measure_no_cam'), textAlign: TextAlign.center, style: TextStyle(fontSize: 13.5, height: 1.4, color: cs.error.withValues(alpha: 0.85))),
            ] else if (h.measureFailed && h.measureNofeed) ...[
              const SizedBox(height: 12),
              Text(t('health.measure_nofeed'), textAlign: TextAlign.center, style: TextStyle(fontSize: 13.5, height: 1.4, color: cs.error.withValues(alpha: 0.85))),
            ] else if (h.measureFailed) ...[
              const SizedBox(height: 12),
              Text(t('health.measure_fail'), textAlign: TextAlign.center, style: TextStyle(fontSize: 13.5, height: 1.4, color: Flat.muted(context))),
            ],
            const SizedBox(height: 14),
            Center(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 22)),
                onPressed: () => unawaited(h.measureWithCamera()),
                icon: const Icon(Icons.waving_hand_outlined, size: 20),
                label: Text(t(h.cameraBpm == null ? 'health.measure' : 'health.measure_again'), style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _measureArea(BuildContext context, ColorScheme cs) {
    final h = widget.health;
    final ctrl = h.cameraPreview;
    // A big warm, near-white panel: with the finger pressed over the front camera, this
    // bright surface IS the light source for the reading. The small round window shows
    // the live stream so frames keep flowing.
    return Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
      Text(t('health.measure_left', {'n': '${h.measureLeft}'}),
          style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, height: 1, fontFeatures: [FontFeature.tabularFigures()])),
      const SizedBox(height: 12),
      Center(
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
          decoration: BoxDecoration(
            color: const Color(0xFFFDF1E0),
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFFFFFBF4), Color(0xFFFBEEDC)],
            ),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Column(children: [
            ClipOval(
              child: Container(
                width: 130,
                height: 130,
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0x338A6D3B), width: 3),
                ),
                child: ctrl == null
                    ? const ColoredBox(color: Color(0xFFFFF6EA))
                    : CameraPreview(ctrl),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              t('health.measure_tip'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13.5, height: 1.45, color: Colors.black.withValues(alpha: 0.78)),
            ),
          ]),
        ),
      ),
      const SizedBox(height: 12),
      const LinearProgressIndicator(minHeight: 2),
    ]);
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
          ] else if (h.hospitalsNoLocation && list.isEmpty) ...[
            Padding(padding: const EdgeInsets.all(16), child: Text(t('health.hosp_location'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, height: 1.45))),
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
