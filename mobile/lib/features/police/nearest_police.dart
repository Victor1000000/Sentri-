import 'dart:math' as math;

import 'police_directory.dart';

/// Where each state command's area is centred, as the state capital. Used only to pick the closest commands
/// to a position, so it is approximate: near a state border the nearest capital can be the neighbour's.
/// The screen says so. Real boundaries (an imported state boundary file) would make this exact.
const stateCentres = <String, (double, double)>{
  'Abia': (5.53, 7.49), 'Adamawa': (9.20, 12.48), 'Akwa Ibom': (5.03, 7.93), 'Anambra': (6.21, 7.07),
  'Bauchi': (10.31, 9.84), 'Bayelsa': (4.92, 6.26), 'Benue': (7.73, 8.52), 'Borno': (11.85, 13.16),
  'Cross River': (4.96, 8.33), 'Delta': (6.20, 6.73), 'Ebonyi': (6.32, 8.11), 'Edo': (6.34, 5.63),
  'Ekiti': (7.62, 5.22), 'Enugu': (6.46, 7.55), 'FCT (Abuja)': (9.06, 7.49), 'Gombe': (10.29, 11.17),
  'Imo': (5.48, 7.03), 'Jigawa': (11.76, 9.34), 'Kaduna': (10.52, 7.44), 'Kano': (12.00, 8.52),
  'Katsina': (12.99, 7.60), 'Kebbi': (12.45, 4.20), 'Kogi': (7.80, 6.74), 'Kwara': (8.50, 4.55),
  'Lagos': (6.60, 3.35), 'Nasarawa': (8.49, 8.52), 'Niger': (9.61, 6.55), 'Ogun': (7.16, 3.35),
  'Ondo': (7.25, 5.19), 'Osun': (7.77, 4.56), 'Oyo': (7.38, 3.95), 'Plateau': (9.90, 8.86),
  'Rivers': (4.82, 7.05), 'Sokoto': (13.06, 5.24), 'Taraba': (8.89, 11.36), 'Yobe': (11.75, 11.96),
  'Zamfara': (12.17, 6.66),
};

class NearbyCommand {
  const NearbyCommand(this.command, this.km);
  final PoliceCommand command;
  final int km;
}

/// The closest command and the ones around it, nearest first.
class NearPolice {
  const NearPolice(this.primary, this.nearby);
  final NearbyCommand primary;
  final List<NearbyCommand> nearby;
}

double _km(double la1, double lo1, double la2, double lo2) {
  const r = 6371.0;
  double rad(double d) => d * math.pi / 180;
  final a = math.pow(math.sin(rad(la2 - la1) / 2), 2) + math.cos(rad(la1)) * math.cos(rad(la2)) * math.pow(math.sin(rad(lo2 - lo1) / 2), 2);
  return 2 * r * math.asin(math.sqrt(a));
}

/// The command closest to a position plus [others] around it. Null when the directory has nothing usable.
NearPolice? nearestPolice(PoliceDirectory dir, double lat, double lon, {int others = 2}) {
  final ranked = <NearbyCommand>[
    for (final c in dir.commands)
      if (stateCentres[c.state] != null && c.lines.isNotEmpty) NearbyCommand(c, _km(lat, lon, stateCentres[c.state]!.$1, stateCentres[c.state]!.$2).round()),
  ]..sort((a, b) => a.km.compareTo(b.km));
  if (ranked.isEmpty) return null;
  return NearPolice(ranked.first, ranked.skip(1).take(others).toList());
}

/// 0803 541 5408 style, so a number is easy to read and to say aloud.
String prettyLine(String n) {
  final d = n.replaceAll(RegExp(r'\D'), '');
  return d.length == 11 ? '${d.substring(0, 4)} ${d.substring(4, 7)} ${d.substring(7)}' : n;
}
