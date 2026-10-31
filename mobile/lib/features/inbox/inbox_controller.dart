import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/net/api.dart';

/// What the message bar and the Messages screen show. Refreshed when the app opens, when a push
/// arrives, and when the person pulls to refresh.
class InboxController extends ChangeNotifier {
  InboxController(this.api, {this.onOver, this.onUrgent});
  final SentriApi api;

  /// Called for an urgent alert that is no longer waiting for anyone (answered or ended), so its
  /// ringing notification can be removed.
  final Future<void> Function(String inboxId)? onOver;

  /// Called once for a live emergency that is still waiting for someone, so a phone that was offline or locked
  /// when the push was due still rings the moment it is back online and the app reconciles with the server.
  final Future<void> Function(InboxEntry e)? onUrgent;
  final Set<String> _rung = {};

  InboxList _data = const InboxList();
  bool loading = false;
  bool failed = false;

  /// True when the last refresh failed because this phone's session is no longer valid (401).
  /// The screen then asks the person to sign in again instead of blaming the connection.
  bool failedAuth = false;

  InboxList get data => _data;
  int get unread => _data.unread + _data.invites.length;

  /// The newest unread alert that needs action, for the bar on the home screen.
  InboxEntry? get headline {
    final unread = _data.items.where((i) => !i.read && !i.isShare && i.kind != 'test').toList();
    final urgent = unread.where((i) => i.urgent && i.live).toList();
    return urgent.isNotEmpty ? urgent.first : (unread.isNotEmpty ? unread.first : null);
  }

  Future<void> refresh() async {
    loading = true;
    notifyListeners();
    try {
      _data = await api.inbox();
      failed = false;
      failedAuth = false;
      for (final e in _data.items) {
        if (e.urgent && e.state != 'active') unawaited(onOver?.call(e.id));
        // Only recent, still-unanswered emergencies ring again; the push may already have rung this phone.
        if (e.urgent && e.live && e.state == 'active' && !e.read && DateTime.now().difference(e.at) < const Duration(minutes: 30) && _rung.add(e.id)) {
          unawaited(onUrgent?.call(e));
        }
      }
    } catch (e) {
      failed = true;
      failedAuth = e is ApiHttpError && e.status == 401;
    }
    loading = false;
    notifyListeners();
  }

  Future<void> decide(InboxInvite i, {required bool accept}) async {
    try {
      await api.decideInvite(i.contactId, accept: accept);
    } catch (_) {}
    await refresh();
  }
}
