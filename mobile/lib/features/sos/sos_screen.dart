import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/i18n/i18n.dart';
import '../police/police_call_card.dart';
import '../police/police_directory.dart';
import 'pin_pad.dart';
import 'sos_controller.dart';

/// Full-screen alert view. Shows over the lock screen (the Android activity is set to do that).
/// It is shown for [SosPhase.countdown], [SosPhase.active] and [SosPhase.acknowledged] only;
/// after a duress PIN the controller reports idle, so this screen disappears exactly as on a cancel.
class SosScreen extends StatefulWidget {
  const SosScreen({super.key, required this.sos, required this.i18n, required this.police});
  final SosController sos;
  final I18n i18n;
  final Future<PoliceDirectory> police;

  @override
  State<SosScreen> createState() => _SosScreenState();
}

class _SosScreenState extends State<SosScreen> {
  final _padKey = GlobalKey<PinPadState>();
  String? _messageKey;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Repaint a few times a second so the countdown number stays current.
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _submit(String pin) async {
    final r = await widget.sos.submitPin(pin);
    if (!mounted) return;
    switch (r) {
      case PinUiResult.cancelled:
        break; // the controller moves to idle and this screen is removed
      case PinUiResult.wrong:
        _padKey.currentState?.clear();
        setState(() => _messageKey = 'sos.wrong_pin');
      case PinUiResult.locked:
        _padKey.currentState?.clear();
        setState(() => _messageKey = 'sos.locked');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.i18n.t;
    final phase = widget.sos.phase;
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    var secs = 0;
    var fraction = 0.0;
    String headline;
    switch (phase) {
      case SosPhase.countdown:
        final end = widget.sos.windowEndsAt;
        final ms = end == null ? 0 : end.difference(DateTime.now()).inMilliseconds;
        secs = (ms / 1000).ceil().clamp(0, 99);
        fraction = (ms / 5000).clamp(0.0, 1.0);
        headline = t('sos.countdown', {'seconds': '$secs'});
      case SosPhase.active:
        headline = t('sos.active');
      case SosPhase.acknowledged:
        headline = t('sos.responding');
      case SosPhase.idle:
        headline = '';
    }

    final calm = phase == SosPhase.acknowledged;
    final accent = calm ? cs.tertiary : cs.error;

    return Scaffold(
      backgroundColor: Color.alphaBlend(accent.withValues(alpha: 0.10), cs.surface),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Status badge: a ring that drains during the cancel window, then a solid dot.
                SizedBox(
                  width: 132,
                  height: 132,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox.expand(
                        child: CircularProgressIndicator(
                          value: phase == SosPhase.countdown ? fraction : 1,
                          strokeWidth: 8,
                          color: accent,
                          backgroundColor: accent.withValues(alpha: 0.18),
                        ),
                      ),
                      if (phase == SosPhase.countdown)
                        Text('$secs', style: text.displayMedium?.copyWith(color: accent, fontWeight: FontWeight.w800))
                      else
                        Icon(calm ? Icons.check_rounded : Icons.shield_rounded, size: 56, color: accent),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Text(headline, textAlign: TextAlign.center, style: text.headlineMedium),
                if (widget.sos.offlineQueued) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(color: cs.surface, borderRadius: BorderRadius.circular(10), border: Border.all(color: cs.outlineVariant)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.cloud_off_outlined, size: 18),
                        const SizedBox(width: 8),
                        Flexible(child: Text(t('sos.offline'), style: text.bodyMedium)),
                      ],
                    ),
                  ),
                ],
                if (phase != SosPhase.countdown) ...[
                  const SizedBox(height: 20),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Column(children: [
                      // Honest about what the app does: it alerts your contacts, and you reach the police by calling.
                      Text(t('sos.police_note'), textAlign: TextAlign.center, style: text.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 10),
                      PoliceCallCard(directory: widget.police, i18n: widget.i18n, lat: widget.sos.lastGeo?.lat, lon: widget.sos.lastGeo?.lon),
                    ]),
                  ),
                ],
                const SizedBox(height: 28),
                if (calm)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 320),
                    child: FilledButton(onPressed: widget.sos.dismiss, child: Text(t('sos.im_safe'))),
                  )
                else ...[
                  Text(t('sos.enter_pin'), style: text.titleMedium),
                  const SizedBox(height: 12),
                  PinPad(key: _padKey, onSubmit: (p) => unawaited(_submit(p))),
                  SizedBox(
                    height: 36,
                    child: _messageKey == null
                        ? null
                        : Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Text(t(_messageKey!), style: TextStyle(color: cs.error, fontWeight: FontWeight.w600)),
                          ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
