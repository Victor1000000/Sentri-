import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/i18n/i18n.dart';
import '../../core/net/api.dart';

/// Shows the people who get your alerts, and whether each one agreed to it.
/// Changing the list is done in onboarding; it is locked while an alert is running.
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key, required this.api, required this.i18n});
  final SentriApi api;
  final I18n i18n;

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  late Future<List<ContactStatus>> _future = widget.api.listContacts();

  void _reload() => setState(() => _future = widget.api.listContacts());

  /// 0803 123 4567 style, so numbers are easy to recognise at a glance.
  static String pretty(String e164) {
    if (e164.startsWith('+234') && e164.length == 14) {
      final n = '0${e164.substring(4)}';
      return '${n.substring(0, 4)} ${n.substring(4, 7)} ${n.substring(7)}';
    }
    return e164;
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.i18n.t;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t('contacts.title'))),
      body: FutureBuilder<List<ContactStatus>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(t('contacts.load_failed'), textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  OutlinedButton(onPressed: _reload, child: Text(t('contacts.retry'))),
                ]),
              ),
            );
          }
          final list = snap.data ?? const [];
          final declined = list.where((c) => c.consent == 'declined').length;
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              Text(t('contacts.help'), style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 16),
              Card(
                child: Column(
                  children: [
                    for (var i = 0; i < list.length; i++) ...[
                      if (i > 0) const Divider(height: 1),
                      ListTile(
                        title: Text(pretty(list[i].phone), style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(list[i].reachable ? t('contacts.on_sentri') : t('contacts.not_on_sentri'), style: TextStyle(fontSize: 13, color: list[i].reachable ? cs.tertiary : cs.onSurface.withValues(alpha: 0.55))),
                        trailing: list[i].reachable ? _Chip(list[i].consent, t) : TextButton(onPressed: () => Share.share(t('share.invite_text')), child: Text(t('share.invite'))),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(t('contacts.app_only'), style: Theme.of(context).textTheme.bodySmall),
              if (declined > 0) ...[
                const SizedBox(height: 16),
                Text(t('contacts.declined_note'), style: TextStyle(color: cs.error, fontWeight: FontWeight.w600)),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.status, this.t);
  final String status;
  final String Function(String, [Map<String, String>]) t;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final warn = Theme.of(context).brightness == Brightness.dark ? const Color(0xFFE3A13A) : const Color(0xFFA8650A);
    final color = switch (status) { 'accepted' => cs.tertiary, 'declined' => cs.error, _ => warn };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(99), border: Border.all(color: color)),
      child: Text(t('contacts.$status'), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
    );
  }
}
