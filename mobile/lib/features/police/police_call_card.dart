import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/i18n/i18n.dart';
import '../../core/widgets/flat.dart';
import '../../core/widgets/glass.dart';
import 'nearest_police.dart';
import 'police_directory.dart';

/// "Call the police near here": the national emergency number first, then the closest state command's
/// lines, each a one-tap dial button (it opens the phone app with the number ready; the person taps call).
/// Shown to the person in trouble and to their contacts, using the live position.
///
/// The state lines come from a public list that the police have not confirmed, and the card says so. 112 is
/// the official national emergency number.
class PoliceCallCard extends StatefulWidget {
  const PoliceCallCard({super.key, required this.directory, required this.i18n, this.lat, this.lon, this.forContact = false});
  final Future<PoliceDirectory> directory;
  final I18n i18n;
  /// Null until the first position fix: the card then offers 112 only.
  final double? lat;
  final double? lon;

  /// Wording for a contact looking at someone else's alert: "near them".
  final bool forContact;

  @override
  State<PoliceCallCard> createState() => _PoliceCallCardState();
}

class _PoliceCallCardState extends State<PoliceCallCard> {
  bool _more = false;
  String? _error;

  Future<void> _dial(String number) async {
    final ok = await launchUrl(Uri(scheme: 'tel', path: number.replaceAll(RegExp(r'[^0-9+]'), '')));
    if (!ok && mounted) setState(() => _error = widget.i18n.t('police.cant_dial'));
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.i18n.t;
    return FutureBuilder<PoliceDirectory>(
      future: widget.directory,
      builder: (context, snap) {
        final near = snap.hasData && widget.lat != null && widget.lon != null ? nearestPolice(snap.data!, widget.lat!, widget.lon!) : null;
        return Glass(
          radius: 22,
          padding: const EdgeInsets.all(16),
          tint: Flat.danger,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(shape: BoxShape.circle, color: Flat.danger.withValues(alpha: 0.14)),
                child: const Icon(Icons.local_police_outlined, size: 19, color: Flat.danger),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(widget.forContact ? t('police.near_them') : t('police.near_you'), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, letterSpacing: -0.2)),
              ),
            ]),
            const SizedBox(height: 14),
            _DialButton(label: t('police.call_112'), big: true, onTap: () => unawaited(_dial('112'))),
            if (near != null) ...[
              const SizedBox(height: 14),
              Text('${near.primary.command.state} · ${t('police.command')}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              for (final l in near.primary.command.lines.take(3)) Padding(padding: const EdgeInsets.only(bottom: 8), child: _DialButton(label: t('police.call', {'n': prettyLine(l)}), onTap: () => unawaited(_dial(l)))),
              Text(t('police.approx'), style: TextStyle(fontSize: 12, height: 1.4, color: Flat.muted(context))),
              if (near.nearby.isNotEmpty) ...[
                const SizedBox(height: 6),
                TextButton(
                  style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 32), alignment: Alignment.centerLeft),
                  onPressed: () => setState(() => _more = !_more),
                  child: Text(_more ? t('police.hide_nearby') : t('police.also_near')),
                ),
                if (_more)
                  for (final n in near.nearby) ...[
                    Padding(padding: const EdgeInsets.only(top: 6, bottom: 6), child: Text('${n.command.state} · ${t('police.km', {'n': '${n.km}'})}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
                    for (final l in n.command.lines.take(2)) Padding(padding: const EdgeInsets.only(bottom: 8), child: _DialButton(label: t('police.call', {'n': prettyLine(l)}), onTap: () => unawaited(_dial(l)))),
                  ],
              ],
            ] else if (snap.connectionState == ConnectionState.done) ...[
              const SizedBox(height: 10),
              Text(widget.lat == null ? t('police.waiting') : t('police.none_found'), style: TextStyle(fontSize: 13, color: Flat.muted(context))),
            ],
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(fontSize: 13, color: Flat.danger))),
          ]),
        );
      },
    );
  }
}

class _DialButton extends StatelessWidget {
  const _DialButton({required this.label, required this.onTap, this.big = false});
  final String label;
  final VoidCallback onTap;
  final bool big;
  @override
  Widget build(BuildContext context) {
    final color = big ? Flat.danger : Theme.of(context).colorScheme.onSurface;
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: big ? Flat.danger : Colors.white.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.08 : 0.55),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            height: big ? 54 : 46,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: big ? null : BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: color.withValues(alpha: 0.14))),
            child: Row(children: [
              Icon(Icons.call, size: big ? 22 : 19, color: big ? Colors.white : color),
              const SizedBox(width: 10),
              Expanded(child: Text(label, style: TextStyle(fontSize: big ? 17 : 15, fontWeight: FontWeight.w600, color: big ? Colors.white : color))),
            ]),
          ),
        ),
      ),
    );
  }
}
