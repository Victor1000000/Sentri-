import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sentri/features/police/nearest_police.dart';
import 'package:sentri/features/police/police_directory.dart';

void main() {
  final dir = PoliceDirectory.parse(File('assets/directory/police_directory.json').readAsStringSync());

  test('a position in Lagos picks Lagos first, with Ogun and Oyo around it', () {
    final r = nearestPolice(dir, 6.5244, 3.3792)!;
    expect(r.primary.command.state, 'Lagos');
    expect(r.nearby.map((c) => c.command.state), containsAll(['Ogun']));
    expect(r.nearby.length, 2);
    expect(r.primary.km, lessThan(r.nearby.first.km));
  });

  test('a position in Kano picks Kano', () {
    expect(nearestPolice(dir, 12.0022, 8.5920)!.primary.command.state, 'Kano');
  });

  test('every state has a centre so none is silently skipped', () {
    for (final c in dir.commands) {
      expect(stateCentres.containsKey(c.state), isTrue, reason: c.state);
    }
  });

  test('an empty directory gives null', () {
    expect(nearestPolice(PoliceDirectory(const []), 6.5, 3.4), isNull);
  });

  test('prettyLine groups an 11 digit number', () {
    expect(prettyLine('08035415408'), '0803 541 5408');
    expect(prettyLine('112'), '112');
  });
}
