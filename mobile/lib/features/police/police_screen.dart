import 'dart:async';
import 'dart:ui' show FontFeature;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/i18n/i18n.dart';
import '../photos/photo_police.dart';
import 'police_directory.dart';

/// Digits only (plus a leading +), so a copied line with spaces dials correctly.
String _dialable(String l) => '+${l.replaceAll(RegExp(r'[^0-9]'), '')}'.replaceFirst('++', '+');

/// Lists every state command with its public lines. Numbers are selectable so they can be copied
/// — and now they can be dialled right there: one tap on the green call button beside a line,
/// no copy-paste needed. Shows the command for the user's current state first, when known.
class PoliceScreen extends StatelessWidget {
  const PoliceScreen({super.key, required this.directory, required this.i18n, this.currentState});
  final PoliceDirectory? directory;
  final I18n i18n;
  final String? currentState;

  @override
  Widget build(BuildContext context) {
    final t = i18n.t;
    final cs = Theme.of(context).colorScheme;
    final dir = directory;
    final mine = dir?.forState(currentState);
    Widget listBuilder(double offset) => ListView(
          // Bouncy pull like the rest of the refreshed screens.
          physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            // The tab opens on a real officer's face, not on a form: a Nigerian
            // police banner that slides gently as the page scrolls (parallax).
            ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: SizedBox(
                height: 150,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Transform.translate(
                      offset: Offset(0, (-offset * 0.35).clamp(-60.0, 60.0)),
                      child: Image.memory(photoPoliceBytes, fit: BoxFit.cover, gaplessPlayback: true),
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
            ),
            const SizedBox(height: 18),
            if (mine != null) ...[
              Text(t('police.your_state').toUpperCase(), style: Theme.of(context).textTheme.labelMedium?.copyWith(letterSpacing: 1.1, color: cs.outline)),
              const SizedBox(height: 8),
              Card(child: _CommandTile(mine, i18n)),
              const SizedBox(height: 20),
            ],
            Text(t('police.note'), style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 16),
            Text(t('police.all').toUpperCase(), style: Theme.of(context).textTheme.labelMedium?.copyWith(letterSpacing: 1.1, color: cs.outline)),
            const SizedBox(height: 8),
            Card(
              child: Column(
                children: [
                  for (var i = 0; i < dir.commands.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    _CommandTile(dir.commands[i], i18n),
                  ],
                ],
              ),
            ),
          ],
        );
    return Scaffold(
      appBar: AppBar(title: Text(t('tabs.police'))),
      body: dir == null ? const Center(child: CircularProgressIndicator()) : _ParallaxList(builder: listBuilder),
    );
  }
}

/// Holds the scroll offset so the banner above can slide while the list moves.
/// A plain StatefulWidget rebuilds the list with the latest offset; cheap and honest.
class _ParallaxList extends StatefulWidget {
  const _ParallaxList({required this.builder});
  final Widget Function(double offset) builder;
  @override
  State<_ParallaxList> createState() => _ParallaxListState();
}

class _ParallaxListState extends State<_ParallaxList> {
  double _offset = 0;
  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.axis == Axis.vertical && n.metrics.pixels != _offset) {
          setState(() => _offset = n.metrics.pixels);
        }
        return false;
      },
      child: widget.builder(_offset),
    );
  }
}

class _CommandTile extends StatelessWidget {
  const _CommandTile(this.c, this.i18n);
  final PoliceCommand c;
  final I18n i18n;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final official = c.verified || c.npfListed;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(c.state, style: Theme.of(context).textTheme.titleMedium)),
              if (official)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(99),
                    border: Border.all(color: cs.tertiary),
                  ),
                  child: Text(
                    i18n.t(c.verified ? 'police.verified' : 'police.listed'),
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: cs.tertiary),
                  ),
                ),
            ],
          ),
          if (c.commissioner != null) ...[
            const SizedBox(height: 4),
            Text(
              '${i18n.t('police.commissioner')}: ${c.commissioner}',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.onSurface),
            ),
          ],
          const SizedBox(height: 6),
          for (final l in c.lines)
            Row(children: [
              Expanded(
                child: SelectableText(l, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()])),
              ),
              IconButton(
                tooltip: 'Call',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.call, color: cs.primary),
                onPressed: () {
                  final n = _dialable(l);
                  unawaited(launchUrl(Uri(scheme: 'tel', path: n), mode: LaunchMode.externalApplication).catchError((_) => false));
                },
              ),
            ]),
        ],
      ),
    );
  }
}
