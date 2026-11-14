import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/i18n/i18n.dart';
import '../../core/widgets/flat.dart';
import '../push/push_service.dart';

/// Watches (v41). Honest by design: a paired Wear OS watch mirrors the phone's
/// notifications by itself - that is the operating system, not an app feature.
/// This screen explains it in one breath and rings a harmless test ping, so the
/// person can watch it land on their wrist and know that every real alert -
/// SOS rings included - will reach it the same way.
class WatchScreen extends StatefulWidget {
  const WatchScreen({super.key, required this.i18n});
  final I18n i18n;

  @override
  State<WatchScreen> createState() => _WatchScreenState();
}

class _WatchScreenState extends State<WatchScreen> {
  String? _msg;

  Future<void> _test() async {
    final t = widget.i18n.t;
    unawaited(showWatchTestNote(t('watch.test_title'), t('watch.test_body')));
    if (mounted) setState(() => _msg = t('watch.test_sent'));
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.i18n.t;
    final text = Theme.of(context).textTheme;
    return FlatPage(
      title: t('watch.title'),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12)),
                  child: Icon(Icons.watch_outlined, size: 24, color: Theme.of(context).colorScheme.primary),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(t('watch.paired'), style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
              ]),
              const SizedBox(height: 14),
              Text(t('watch.intro'), style: TextStyle(fontSize: 14.5, height: 1.5, color: Flat.muted(context))),
              const SizedBox(height: 10),
              Text(t('watch.works'), style: TextStyle(fontSize: 14.5, height: 1.5, color: Flat.muted(context))),
            ]),
          ),
        ),
        const SizedBox(height: 16),
        FlatButton(label: t('watch.test_btn'), onPressed: () => unawaited(_test())),
        if (_msg != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_msg!, textAlign: TextAlign.center, style: TextStyle(fontSize: 13.5, color: Flat.muted(context)))),
        const SizedBox(height: 12),
        Text(t('watch.note'), textAlign: TextAlign.center, style: TextStyle(fontSize: 13, height: 1.45, color: Flat.muted(context))),
      ],
    );
  }
}
