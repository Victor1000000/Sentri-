/// Shapes the server sends for the in-app inbox and live location sharing. Parsing is forgiving:
/// a missing or odd field becomes a safe default rather than an exception.
DateTime _ms(Object? v) => DateTime.fromMillisecondsSinceEpoch(v is num ? v.toInt() : 0);
String _s(Object? v, [String d = '']) => v is String ? v : d;

class InboxEntry {
  const InboxEntry({required this.id, required this.kind, required this.from, required this.text, required this.at, required this.read, required this.live, this.state = 'active'});
  final String id;

  /// sos | duress | offline | low_battery | test | share_start | share_stop
  final String kind;
  final String? from;
  final String text;
  final DateTime at;
  final bool read;
  final bool live;

  /// active | responding | ended
  final String state;

  bool get urgent => kind == 'sos' || kind == 'duress' || kind == 'offline';
  bool get isShare => kind == 'share_start' || kind == 'share_stop';

  factory InboxEntry.fromJson(Map<String, dynamic> j) => InboxEntry(
        id: _s(j['id']),
        kind: _s(j['kind'], 'sos'),
        from: j['from'] is String ? j['from'] as String : null,
        text: _s(j['text']),
        at: _ms(j['at']),
        read: j['read'] == true,
        live: j['live'] == true,
        state: const {'active', 'responding', 'ended'}.contains(j['state']) ? j['state'] as String : (j['live'] == true ? 'active' : 'ended'),
      );
}

class InboxInvite {
  const InboxInvite({required this.contactId, required this.fromName});
  final String contactId;
  final String? fromName;
}

class InboxList {
  const InboxList({this.unread = 0, this.items = const [], this.invites = const []});
  final int unread;
  final List<InboxEntry> items;
  final List<InboxInvite> invites;

  factory InboxList.fromJson(Map<String, dynamic> j) => InboxList(
        unread: j['unread'] is num ? (j['unread'] as num).toInt() : 0,
        items: [for (final i in (j['items'] as List? ?? const [])) if (i is Map<String, dynamic>) InboxEntry.fromJson(i)],
        invites: [
          for (final i in (j['invites'] as List? ?? const []))
            if (i is Map && i['contactId'] is String) InboxInvite(contactId: i['contactId'] as String, fromName: i['fromName'] is String ? i['fromName'] as String : null),
        ],
      );
}

class InboxDetail {
  const InboxDetail({required this.entry, required this.state, this.lat, this.lon, this.geoAt, this.callPhone, required this.canRespond});
  final InboxEntry entry;

  /// active | responding | ended
  final String state;
  final double? lat;
  final double? lon;
  final DateTime? geoAt;

  /// Absent for a duress alert on purpose: a call could put the person at risk.
  final String? callPhone;
  final bool canRespond;

  factory InboxDetail.fromJson(Map<String, dynamic> j) {
    final g = j['geo'];
    return InboxDetail(
      entry: InboxEntry.fromJson(j),
      state: _s(j['state'], 'ended'),
      lat: g is Map && g['lat'] is num ? (g['lat'] as num).toDouble() : null,
      lon: g is Map && g['lon'] is num ? (g['lon'] as num).toDouble() : null,
      geoAt: g is Map ? _ms(g['at']) : null,
      callPhone: j['callPhone'] is String ? j['callPhone'] as String : null,
      canRespond: j['canRespond'] == true,
    );
  }
}

/// A location share that is running now.
class ShareInfo {
  const ShareInfo({required this.id, required this.expiresAt, required this.contactIds});
  final String id;
  final DateTime expiresAt;
  final List<String> contactIds;

  factory ShareInfo.fromJson(Map<String, dynamic> j) => ShareInfo(
        id: _s(j['id']),
        expiresAt: _ms(j['expiresAt']),
        contactIds: [for (final c in (j['contactIds'] as List? ?? const [])) if (c is String) c],
      );
}

class ShareStartResult {
  const ShareStartResult({required this.id, required this.expiresAt, required this.reached, required this.unreachable});
  final String id;
  final DateTime expiresAt;
  final int reached;
  final List<String> unreachable;
}

class TestAlertResult {
  const TestAlertResult({required this.sent, required this.reachable, required this.total});
  final int sent;
  final int reachable;
  final int total;
}
