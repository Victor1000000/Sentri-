import 'dart:convert';

/// One state police command's public lines, as loaded from assets/directory/police_directory.json.
class PoliceCommand {
  const PoliceCommand({required this.state, required this.lines, this.commissioner, this.commissionerNote, this.commissionerAsOf, required this.verified, this.npfListed = false});
  final String state;
  final List<String> lines;

  /// Commissioner of Police. Null until confirmed with the command.
  final String? commissioner;

  /// Where the name came from and how sure we are. Shown next to the name.
  final String? commissionerNote;

  /// Month the posting was reported, e.g. 2026-08.
  final String? commissionerAsOf;

  /// True only once the command confirmed the lines. Until then the UI shows "Unverified" and the
  /// backend must not alert them.
  final bool verified;

  /// True when these lines are on the list the Nigeria Police Force itself published. That is not the same as
  /// verified: nobody has called them. The UI says "Listed by NPF", never "Verified".
  final bool npfListed;

  factory PoliceCommand.fromJson(Map<String, dynamic> j) => PoliceCommand(
        state: j['state'] as String,
        lines: [for (final l in (j['lines'] as List)) l as String],
        commissioner: j['commissioner'] as String?,
        commissionerNote: j['commissionerNote'] as String?,
        commissionerAsOf: j['commissionerAsOf'] as String?,
        verified: j['verified'] as bool? ?? false,
        npfListed: j['npfListed'] as bool? ?? false,
      );
}

class PoliceDirectory {
  PoliceDirectory(this.commands, {this.source});
  final List<PoliceCommand> commands;
  final String? source;

  factory PoliceDirectory.parse(String raw) {
    final j = jsonDecode(raw) as Map<String, dynamic>;
    final list = [for (final c in (j['commands'] as List)) PoliceCommand.fromJson(c as Map<String, dynamic>)]
      ..sort((a, b) => a.state.compareTo(b.state));
    return PoliceDirectory(list, source: j['source'] as String?);
  }

  /// Matches a state name from a place lookup ("Lagos", "Federal Capital Territory", "FCT").
  PoliceCommand? forState(String? name) {
    if (name == null) return null;
    final n = _norm(name);
    for (final c in commands) {
      final cn = _norm(c.state);
      if (cn == n || (cn.startsWith('fct') && (n.contains('federalcapital') || n == 'fct' || n.contains('abuja')))) return c;
    }
    return null;
  }

  static String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'\bstate\b'), '').replaceAll(RegExp(r'[^a-z]'), '');
}
