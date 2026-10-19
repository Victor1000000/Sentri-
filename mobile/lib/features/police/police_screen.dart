import 'dart:ui' show FontFeature;
import 'package:flutter/material.dart';

import '../../core/i18n/i18n.dart';
import 'police_directory.dart';

/// Lists every state command with its public lines. Numbers are selectable so they can be copied.
/// Shows the command for the user's current state first, when known.
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
    return Scaffold(
      appBar: AppBar(title: Text(t('tabs.police'))),
      body: dir == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              children: [
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
            ),
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
    final warn = Theme.of(context).brightness == Brightness.dark ? const Color(0xFFE3A13A) : const Color(0xFFA8650A);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(c.state, style: Theme.of(context).textTheme.titleMedium)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(color: c.verified ? cs.tertiary : warn),
                ),
                child: Text(
                  i18n.t(c.verified ? 'police.verified' : (c.npfListed ? 'police.listed' : 'police.unverified')),
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: c.verified ? cs.tertiary : warn),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${i18n.t('police.commissioner')}: ${c.commissioner ?? i18n.t('police.to_confirm')}',
            style: TextStyle(fontSize: 13, fontWeight: c.commissioner != null ? FontWeight.w600 : FontWeight.w400, color: c.commissioner != null ? cs.onSurface : cs.outline),
          ),
          if (c.commissioner != null && c.commissionerAsOf != null)
            Text(
              '${i18n.t('police.reported')} ${c.commissionerAsOf}, ${i18n.t('police.unconfirmed')}',
              style: TextStyle(fontSize: 11, color: cs.outline),
            ),
          const SizedBox(height: 6),
          for (final l in c.lines)
            SelectableText(l, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }
}
