import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sentri/features/police/police_directory.dart';

void main() {
  final dir = PoliceDirectory.parse(File('assets/directory/police_directory.json').readAsStringSync());

  test('the lines shown as one-tap call buttons are always real, dialable numbers', () {
    // The alert screen shows the first three lines of the nearest command (two for the ones nearby) as call buttons.
    for (final c in dir.commands) {
      for (final l in c.lines.take(3)) {
        expect(RegExp(r'^\d{9,11}$').hasMatch(l), isTrue, reason: '${c.state}: "$l" is not dialable');
      }
    }
  });

  test('Lagos leads with the Command\'s own control room lines', () {
    final lagos = dir.commands.firstWhere((c) => c.state == 'Lagos');
    expect(lagos.lines.take(3), ['08063299264', '08065154338', '09129229576']);
    expect(lagos.lines, containsAll(['07055462708', '08035963919']));
  });

  test('every state still has at least one line', () {
    for (final c in dir.commands) {
      expect(c.lines, isNotEmpty, reason: c.state);
    }
  });
}
