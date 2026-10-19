import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sentri/core/net/api.dart';
import 'package:sentri/features/police/police_directory.dart';

void main() {
  group('police directory asset', () {
    final dir = PoliceDirectory.parse(File('assets/directory/police_directory.json').readAsStringSync());

    test('has all 36 states and the FCT, each with at least one line', () {
      expect(dir.commands, hasLength(37));
      for (final c in dir.commands) {
        expect(c.lines, isNotEmpty, reason: c.state);
      }
    });

    test('every state is on the NPF published list but none is called verified', () {
      expect(dir.commands.where((c) => !c.npfListed), isEmpty);
      expect(dir.commands.where((c) => c.verified), isEmpty);
    });

    test('numbers look like Nigerian lines (11 digits starting 0) apart from the Lagos state line', () {
      for (final c in dir.commands) {
        for (final l in c.lines.where((l) => RegExp(r'^\d+$').hasMatch(l))) {
          expect(l.length, anyOf(9, 11), reason: '${c.state} $l');
        }
      }
    });

    test('nothing is marked verified', () {
      expect(dir.commands.where((c) => c.verified), isEmpty);
    });

    test('commissioner names exist only for the eight reported August 2026 postings, each with a source note', () {
      final named = dir.commands.where((c) => c.commissioner != null).map((c) => c.state).toSet();
      expect(named, {'Abia', 'Plateau', 'Bayelsa', 'Cross River', 'Anambra', 'Edo', 'Jigawa', 'Delta'});
      for (final c in dir.commands.where((c) => c.commissioner != null)) {
        expect(c.commissionerNote, isNotEmpty, reason: c.state);
        expect(c.commissionerAsOf, '2026-08');
      }
    });

    test('matches place-lookup state names', () {
      expect(dir.forState('Lagos')?.state, 'Lagos');
      expect(dir.forState('Lagos State')?.state, 'Lagos');
      expect(dir.forState('Federal Capital Territory')?.state, 'FCT (Abuja)');
      expect(dir.forState('Akwa Ibom')?.state, 'Akwa Ibom');
      expect(dir.forState('Cross River State')?.state, 'Cross River');
      expect(dir.forState(null), isNull);
      expect(dir.forState('Atlantis'), isNull);
    });
  });

  group('Place', () {
    test('parses the server reply and ignores junk', () {
      final p = Place.fromJson({'label': 'Allen Avenue, Ikeja, Lagos', 'street': 'Allen Avenue', 'area': 'Ikeja', 'state': 'Lagos'});
      expect(p?.street, 'Allen Avenue');
      expect(p?.lga, isNull);
      expect(Place.fromJson(null), isNull);
      expect(Place.fromJson({'street': 'x'}), isNull);
      expect(Place.fromJson({'label': ''}), isNull);
    });
  });

  group('ContactStatus', () {
    test('parses the server list and treats unknown values as pending', () {
      final l = ContactStatus.listFromJson([
        {'phone': '+2348031111111', 'locale': 'en', 'consent': 'accepted'},
        {'phone': '+2348032222222', 'consent': 'weird'},
        {'nope': 1},
      ]);
      expect(l.map((c) => c.consent), ['accepted', 'pending']);
      expect(ContactStatus.listFromJson(null), isEmpty);
    });
  });
}
