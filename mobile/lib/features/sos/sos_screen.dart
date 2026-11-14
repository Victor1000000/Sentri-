import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/emergency.dart';
import '../../core/i18n/i18n.dart';
import '../../core/widgets/flat.dart';
import '../police/police_call_card.dart';
import '../police/police_directory.dart';
import 'pin_pad.dart';
import 'sos_controller.dart';

/// Full-screen alert view — in the flat family now: the grey ground and solid
/// cards the rest of the app wears, with the mood face at the centre. It shows
/// over the lock screen (the Android activity is set to do that), for
/// [SosPhase.countdown], [SosPhase.active] and [SosPhase.acknowledged] only;
/// after a duress PIN the controller reports idle, so this screen disappears
/// exactly as on a cancel.
///
/// The face matches the home screen: while the alert runs it is red and smirk —
/// bigger and bolder here, white on the alarm disc, with the countdown circling
/// it. The contacts card and the cancel PIN sit below like every other flat page.
class SosScreen extends StatefulWidget {
  const SosScreen({super.key, required this.sos, required this.i18n, required this.police, this.country});
  final SosController sos;
  final I18n i18n;
  final Future<PoliceDirectory> police;

  /// The person's own country, so the police card dials the right lines (v41).
  final SentriCountry? country;

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
    final accent = calm ? Flat.live : Flat.danger;

    // The heart of the screen: the mood face on a solid disc, ringed by the
    // countdown. Red and smirking while the alert runs; a calm green with a
    // check when the contacts are on their way.
    Widget core;
    const ink = Colors.white;
    if (phase == SosPhase.countdown) {
      core = Text('$secs', style: text.displayMedium?.copyWith(color: ink, fontWeight: FontWeight.w800));
    } else if (calm) {
      core = const Icon(Icons.check_rounded, size: 52, color: ink);
    } else {
      core = const CustomPaint(painter: MoodFacePainter(1, ink), size: Size(96, 96));
    }
    final face = SizedBox(
      width: 132,
      height: 132,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.expand(
            child: CircularProgressIndicator(
              value: phase == SosPhase.countdown ? fraction : 1,
              strokeWidth: 5,
              color: accent,
              backgroundColor: accent.withValues(alpha: 0.16),
            ),
          ),
          Container(
            width: 112,
            height: 112,
            decoration: BoxDecoration(shape: BoxShape.circle, color: accent),
            alignment: Alignment.center,
            child: core,
          ),
        ],
      ),
    );

    return Scaffold(
      backgroundColor: Color.alphaBlend(accent.withValues(alpha: 0.08), Flat.bg(context)),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                face,
                const SizedBox(height: 20),
                Text(headline, textAlign: TextAlign.center, style: text.headlineMedium),
                if (widget.sos.offlineQueued) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Flat.card(context),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Flat.hairline(context)),
                    ),
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
                      // v41: the position keeps flowing after a contact responds,
                      // so say so - it is why "I'm safe" (not just the ring) ends it.
                      const SizedBox(height: 4),
                      Text(t('sos.share_until_safe'), textAlign: TextAlign.center, style: text.bodySmall?.copyWith(color: Flat.muted(context))),
                      const SizedBox(height: 10),
                      PoliceCallCard(directory: widget.police, i18n: widget.i18n, lat: widget.sos.lastGeo?.lat, lon: widget.sos.lastGeo?.lon, country: widget.country),
                    ]),
                  ),
                ],
                const SizedBox(height: 28),
                if (calm)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 320),
                    child: FlatButton(label: t('sos.im_safe'), onPressed: widget.sos.dismiss),
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
                            child: Text(t(_messageKey!), style: const TextStyle(color: Flat.danger, fontWeight: FontWeight.w600)),
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
