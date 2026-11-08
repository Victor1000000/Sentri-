import 'dart:async';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/i18n/i18n.dart';
import '../../core/net/api.dart';
import '../sos/contact_people.dart';
import '../sos/guardian_badges.dart';

/// Shows the people who get your alerts, and whether each one agreed to it. Each
/// contact can be given a friendly name and one of twenty drawn "security team"
/// characters (saved on this phone only). Changing the list is done in onboarding;
/// it is locked while an alert is running.
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key, required this.api, required this.people, required this.i18n});
  final SentriApi api;
  final ContactPeople people;
  final I18n i18n;

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  late Future<List<ContactStatus>> _future = widget.api.listContacts();
  Map<String, Person> _people = const {};

  @override
  void initState() {
    super.initState();
    unawaited(_loadPeople());
  }

  Future<void> _loadPeople() async {
    final p = await widget.people.load();
    if (mounted) setState(() => _people = p);
  }

  void _reload() => setState(() => _future = widget.api.listContacts());

  /// 0803 123 4567 style, so numbers are easy to recognise at a glance.
  static String pretty(String e164) {
    if (e164.startsWith('+234') && e164.length == 14) {
      final n = '0${e164.substring(4)}';
      return '${n.substring(0, 4)} ${n.substring(4, 7)} ${n.substring(7)}';
    }
    return e164;
  }

  Future<void> _editPerson(ContactStatus c) async {
    final bad = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _PersonSheet(phone: c.phone, existing: _people[c.phone], people: widget.people, i18n: widget.i18n),
    );
    if (bad == true) {
      final fresh = await widget.people.load();
      if (mounted) setState(() => _people = fresh);
    }
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
                        onTap: () => unawaited(_editPerson(list[i])),
                        leading: GuardianAvatar(
                          badge: badgeById(_people[list[i].phone]?.badge ?? guardianBadges.first.id),
                          size: 46,
                        ),
                        // The name the person gave; falls back to the plain number.
                        title: Text(
                          _people[list[i].phone]?.name.isNotEmpty == true
                              ? _people[list[i].phone]!.name
                              : pretty(list[i].phone),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          _people[list[i].phone]?.name.isNotEmpty == true ? pretty(list[i].phone) : (list[i].reachable ? t('contacts.on_sentri') : t('contacts.not_on_sentri')),
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.15,
                            color: _people[list[i].phone]?.name.isNotEmpty == true
                                ? cs.onSurface.withValues(alpha: 0.55)
                                : (list[i].reachable ? cs.tertiary : cs.onSurface.withValues(alpha: 0.55)),
                          ),
                        ),
                        trailing: list[i].reachable
                            ? _Chip(list[i].consent, t)
                            : TextButton(onPressed: () => Share.share(t('share.invite_text')), child: Text(t('share.invite'))),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                t('contacts.characters'),
                style: Theme.of(context).textTheme.bodySmall,
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

/// The editor for one contact: any name they like, plus one of the twenty drawn
/// characters. Saves to the phone's secure store; nothing leaves the device.
class _PersonSheet extends StatefulWidget {
  const _PersonSheet({required this.phone, required this.existing, required this.people, required this.i18n});
  final String phone;
  final Person? existing;
  final ContactPeople people;
  final I18n i18n;

  @override
  State<_PersonSheet> createState() => _PersonSheetState();
}

class _PersonSheetState extends State<_PersonSheet> {
  late final TextEditingController _name = TextEditingController(text: widget.existing?.name ?? '');
  late String _badge = widget.existing?.badge.isEmpty ?? true ? guardianBadges.first.id : widget.existing!.badge;

  String t(String k, [Map<String, String> a = const {}]) => widget.i18n.t(k, a);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pad = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(0, 12, 0, pad),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.78,
        child: Column(children: [
          Container(width: 44, height: 4, decoration: BoxDecoration(color: cs.onSurface.withValues(alpha: 0.25), borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 14),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              children: [
                Text(t('contacts.title'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 14),
                TextField(
                  controller: _name,
                  keyboardType: TextInputType.name,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(hintText: t('contacts.name_hint'), isDense: true, counterText: ''),
                  maxLength: 24,
                ),
                const SizedBox(height: 4),
                Text(t('contacts.characters'), style: TextStyle(fontSize: 13, color: cs.onSurface.withValues(alpha: 0.6))),
                const SizedBox(height: 10),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 104,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 8,
                    childAspectRatio: 0.72,
                  ),
                  itemCount: guardianBadges.length,
                  itemBuilder: (context, i) {
                    final b = guardianBadges[i];
                    final selected = b.id == _badge;
                    return InkWell(
                      onTap: () => setState(() => _badge = b.id),
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: selected ? cs.primary : cs.onSurface.withValues(alpha: 0.12), width: selected ? 2 : 1),
                          color: selected ? cs.primary.withValues(alpha: 0.08) : Colors.transparent,
                        ),
                        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          GuardianAvatar(badge: b, size: 56),
                          const SizedBox(height: 5),
                          Flexible(
                            child: Text(
                              b.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 11.5, fontWeight: selected ? FontWeight.w700 : FontWeight.w500),
                            ),
                          ),
                        ]),
                      ),
                    );
                  },
                ),
                FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                  onPressed: () async {
                    await widget.people.put(Person(
                      phone: widget.phone,
                      name: _name.text.trim(),
                      badge: _badge,
                    ));
                    if (context.mounted) Navigator.of(context).pop(true);
                  },
                  child: Text(t('contacts.save')),
                ),
              ],
            ),
          ),
        ]),
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
