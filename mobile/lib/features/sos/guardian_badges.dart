/// The fun "security team" avatars for emergency contacts: 20 presets - ten
/// command-style posts in both a male and a female look. Everything is drawn in
/// code, so no image assets are needed, and each one looks the same on every phone.
///
/// The look is layered gradients (light on top, darker shadows underneath) over a
/// radar-style ring, to give the small drawn portraits their soft 3D shine.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

enum GuardianKind {
  commander,
  sergeant,
  captain,
  major,
  guard,
  ranger,
  pilot,
  doctor,
  nurse,
  fireChief,
}

extension GuardianKindTitle on GuardianKind {
  /// Kept in English on purpose: the badge is a role name printed on a uniform.
  String get en => switch (this) {
        GuardianKind.commander => 'Commander',
        GuardianKind.sergeant => 'Sergeant',
        GuardianKind.captain => 'Captain',
        GuardianKind.major => 'Major',
        GuardianKind.guard => 'Guard',
        GuardianKind.ranger => 'Ranger',
        GuardianKind.pilot => 'Pilot',
        GuardianKind.doctor => 'Doctor',
        GuardianKind.nurse => 'Nurse',
        GuardianKind.fireChief => 'Fire Chief',
      };
}

/// One preset: who the drawn character is (role + look) and its colour pair.
class GuardianBadge {
  const GuardianBadge({
    required this.id,
    required this.kind,
    required this.female,
    required this.color,
    required this.accent,
  });

  /// Stable short name saved in the contact store, e.g. 'commander_f'.
  final String id;
  final GuardianKind kind;
  final bool female;

  /// Main uniform colour.
  final Color color;

  /// Trim colour: hat, piping, collar.
  final Color accent;

  String get title => kind.en;
}

/// The whole roster, in a nice display order: same rank twice, then mixed looks.
const guardianBadges = <GuardianBadge>[
  GuardianBadge(id: 'commander_m', kind: GuardianKind.commander, female: false, color: Color(0xFF1E3A6E), accent: Color(0xFFD9A441)),
  GuardianBadge(id: 'commander_f', kind: GuardianKind.commander, female: true, color: Color(0xFF1E3A6E), accent: Color(0xFFD9A441)),
  GuardianBadge(id: 'sergeant_m', kind: GuardianKind.sergeant, female: false, color: Color(0xFF2E4A2E), accent: Color(0xFFC8C8C8)),
  GuardianBadge(id: 'sergeant_f', kind: GuardianKind.sergeant, female: true, color: Color(0xFF2E4A2E), accent: Color(0xFFC8C8C8)),
  GuardianBadge(id: 'captain_m', kind: GuardianKind.captain, female: false, color: Color(0xFF153C54), accent: Color(0xFFE4C25A)),
  GuardianBadge(id: 'captain_f', kind: GuardianKind.captain, female: true, color: Color(0xFF153C54), accent: Color(0xFFE4C25A)),
  GuardianBadge(id: 'major_m', kind: GuardianKind.major, female: false, color: Color(0xFF4A3320), accent: Color(0xFFD9A441)),
  GuardianBadge(id: 'major_f', kind: GuardianKind.major, female: true, color: Color(0xFF4A3320), accent: Color(0xFFD9A441)),
  GuardianBadge(id: 'guard_m', kind: GuardianKind.guard, female: false, color: Color(0xFF232A35), accent: Color(0xFF8FA3BF)),
  GuardianBadge(id: 'guard_f', kind: GuardianKind.guard, female: true, color: Color(0xFF232A35), accent: Color(0xFF8FA3BF)),
  GuardianBadge(id: 'ranger_m', kind: GuardianKind.ranger, female: false, color: Color(0xFF3D5A3A), accent: Color(0xFFCCB06A)),
  GuardianBadge(id: 'ranger_f', kind: GuardianKind.ranger, female: true, color: Color(0xFF3D5A3A), accent: Color(0xFFCCB06A)),
  GuardianBadge(id: 'pilot_m', kind: GuardianKind.pilot, female: false, color: Color(0xFF123B63), accent: Color(0xFF9EC4E8)),
  GuardianBadge(id: 'pilot_f', kind: GuardianKind.pilot, female: true, color: Color(0xFF123B63), accent: Color(0xFF9EC4E8)),
  GuardianBadge(id: 'doctor_m', kind: GuardianKind.doctor, female: false, color: Color(0xFF28556A), accent: Color(0xFFF2F6F8)),
  GuardianBadge(id: 'doctor_f', kind: GuardianKind.doctor, female: true, color: Color(0xFF28556A), accent: Color(0xFFF2F6F8)),
  GuardianBadge(id: 'nurse_m', kind: GuardianKind.nurse, female: false, color: Color(0xFF3E6B8A), accent: Color(0xFFF6F9FB)),
  GuardianBadge(id: 'nurse_f', kind: GuardianKind.nurse, female: true, color: Color(0xFF3E6B8A), accent: Color(0xFFF6F9FB)),
  GuardianBadge(id: 'firechief_m', kind: GuardianKind.fireChief, female: false, color: Color(0xFF8A2A22), accent: Color(0xFF2B2B2B)),
  GuardianBadge(id: 'firechief_f', kind: GuardianKind.fireChief, female: true, color: Color(0xFF8A2A22), accent: Color(0xFF2B2B2B)),
];

GuardianBadge badgeById(String id) {
  for (final b in guardianBadges) {
    if (b.id == id) return b;
  }
  return guardianBadges.first;
}

/// The drawn portrait used in the contacts list and the editor.
class GuardianAvatar extends StatelessWidget {
  const GuardianAvatar({super.key, required this.badge, this.size = 48});
  final GuardianBadge badge;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _GuardianPainter(badge)),
    );
  }
}

class _GuardianPainter extends CustomPainter {
  _GuardianPainter(this.badge);
  final GuardianBadge badge;

  static const _maleSkinDark = Color(0xFFB5794A);
  static const _maleSkinLight = Color(0xFFD9A06D);
  static const _femaleSkin = Color(0xFFC98E5F);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final c = Offset(w / 2, h / 2);
    final b = badge;
    final dark = Color.lerp(b.color, Colors.black, 0.35)!;
    final light = Color.lerp(b.color, Colors.white, 0.30)!;

    // Radar ring behind the head gives every avatar the security-response look.
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.05
      ..shader = SweepGradient(
        colors: [b.accent, Color.lerp(b.accent, Colors.white, 0.45)!, b.accent.withValues(alpha: 0.35), b.accent],
      ).createShader(Rect.fromCircle(center: c, radius: w * 0.46));
    canvas.drawCircle(c, w * 0.42, ring);

    // Background disc, lit from the top.
    canvas.drawCircle(c, w * 0.39, Paint()..color = dark);
    canvas.drawCircle(
      Offset(w / 2, h * 0.44),
      w * 0.36,
      Paint()
        ..shader = RadialGradient(
          radius: 0.9,
          colors: [light, b.color],
          stops: const [0.0, 1.0],
        ).createShader(Rect.fromCircle(center: c, radius: w * 0.4)),
    );

    // The rest of the portrait is clipped inside the disc.
    final clip = Path()..addOval(Rect.fromCircle(center: c, radius: w * 0.39));
    canvas.save();
    canvas.clipPath(clip);

    _drawTorso(canvas, w, h, b);
    _drawHead(canvas, w, h, b);
    _drawHeadwear(canvas, w, h, b);

    canvas.restore();
  }

  void _drawTorso(Canvas canvas, double w, double h, GuardianBadge b) {
    final dark = Color.lerp(b.color, Colors.black, 0.35)!;
    final torsoTop = h * 0.72;
    final torso = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color.lerp(b.color, Colors.white, 0.12)!, dark],
      ).createShader(Rect.fromLTRB(0, torsoTop - h * 0.2, w, h));
    final torsoPath = Path()
      ..moveTo(w * 0.14, h)
      ..lineTo(w * 0.14, torsoTop + h * 0.06)
      ..quadraticBezierTo(w / 2, torsoTop - h * 0.10, w * 0.86, torsoTop + h * 0.06)
      ..lineTo(w * 0.86, h)
      ..close();
    canvas.drawPath(torsoPath, torso);
    // Collar trim.
    canvas.drawPath(
      Path()
        ..moveTo(w * 0.34, torsoTop + h * 0.02)
        ..quadraticBezierTo(w / 2, torsoTop - h * 0.045, w * 0.66, torsoTop + h * 0.02),
      Paint()
        ..strokeWidth = w * 0.04
        ..style = PaintingStyle.stroke
        ..color = Color.lerp(b.accent, Colors.white, 0.25)!,
    );
  }

  void _drawHead(Canvas canvas, double w, double h, GuardianBadge b) {
    final skin = b.female ? _femaleSkin : _maleSkinDark;
    final shadowed = Color.lerp(skin, Colors.black, 0.18)!;
    final headRect = Rect.fromCenter(center: Offset(w / 2, h * 0.47), width: w * 0.34, height: h * 0.40);
    canvas.drawOval(headRect, Paint()..color = skin);
    canvas.drawOval(
      Rect.fromCenter(center: Offset(w / 2, h * 0.47), width: w * 0.34, height: h * 0.40),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_maleSkinLight, skin, shadowed],
        ).createShader(headRect),
    );
    // Small ears.
    canvas.drawCircle(Offset(w * 0.335, h * 0.50), w * 0.035, Paint()..color = skin);
    canvas.drawCircle(Offset(w * 0.665, h * 0.50), w * 0.035, Paint()..color = Color.lerp(skin, Colors.black, 0.10)!);
  }

  void _drawHeadwear(Canvas canvas, double w, double h, GuardianBadge b) {
    final darkHat = Color.lerp(b.accent, Colors.black, 0.25)!;
    final litHat = Color.lerp(b.accent, Colors.white, 0.35)!;
    final topShadow = Paint()..color = Colors.white.withValues(alpha: 0.22);

    // Longer hair for the female looks (drawn under every kind of hat).
    if (b.female) {
      final hair = Paint()..color = const Color(0xFF2E2118);
      canvas.drawPath(
        Path()
          ..moveTo(w * 0.30, h * 0.46)
          ..quadraticBezierTo(w * 0.27, h * 0.70, w * 0.34, h * 0.76)
          ..lineTo(w * 0.40, h * 0.66)
          ..lineTo(w * 0.40, h * 0.42)
          ..close()
          ..moveTo(w * 0.70, h * 0.46)
          ..quadraticBezierTo(w * 0.73, h * 0.70, w * 0.66, h * 0.76)
          ..lineTo(w * 0.60, h * 0.66)
          ..lineTo(w * 0.60, h * 0.42)
          ..close(),
        hair,
      );
    }

    switch (b.kind) {
      case GuardianKind.doctor:
      case GuardianKind.nurse:
        // White cap with a coloured cross mark.
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(w / 2, h * 0.315), width: w * 0.30, height: h * 0.10), Radius.circular(w * 0.03)),
          Paint()..color = b.accent,
        );
        final cross = Paint()..color = b.kind == GuardianKind.doctor ? const Color(0xFFB3413A) : const Color(0xFF367A5C);
        canvas.drawRect(Rect.fromCenter(center: Offset(w / 2, h * 0.315), width: w * 0.10, height: h * 0.032), cross);
        canvas.drawRect(Rect.fromCenter(center: Offset(w / 2, h * 0.315), width: w * 0.032, height: h * 0.10), cross);
        break;
      case GuardianKind.pilot:
        // Air pilot cap with a visor.
        canvas.drawOval(
          Rect.fromCenter(center: Offset(w / 2, h * 0.32), width: w * 0.38, height: h * 0.15),
          Paint()..color = b.accent,
        );
        canvas.drawOval(
          Rect.fromCenter(center: Offset(w / 2, h * 0.32), width: w * 0.38, height: h * 0.15),
          Paint()
            ..shader = LinearGradient(colors: [litHat, b.accent, darkHat]).createShader(Rect.fromLTWH(w * 0.31, h * 0.24, w * 0.38, h * 0.16)),
        );
        canvas.drawOval(Rect.fromCenter(center: Offset(w / 2, h * 0.375), width: w * 0.40, height: h * 0.035), Paint()..color = darkHat);
        break;
      case GuardianKind.fireChief:
        // Fire helmet with a shield mark.
        canvas.drawPath(
          Path()
            ..moveTo(w * 0.26, h * 0.40)
            ..quadraticBezierTo(w * 0.26, h * 0.20, w * 0.50, h * 0.20)
            ..quadraticBezierTo(w * 0.74, h * 0.20, w * 0.74, h * 0.40)
            ..close(),
          Paint()..color = Color.lerp(b.accent, Colors.red, 0.5)!,
        );
        canvas.drawOval(Rect.fromCenter(center: Offset(w / 2, h * 0.385), width: w * 0.52, height: h * 0.045), Paint()..color = b.accent);
        canvas.drawCircle(Offset(w / 2, h * 0.30), w * 0.055, Paint()..color = const Color(0xFFF2D24B));
        break;
      case GuardianKind.ranger:
      case GuardianKind.guard:
        // Broad field hat with a brim.
        canvas.drawOval(Rect.fromCenter(center: Offset(w / 2, h * 0.375), width: w * 0.52, height: h * 0.09), Paint()..color = darkHat);
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.33, h * 0.27, w * 0.34, h * 0.11), Radius.circular(w * 0.04)),
          Paint()..color = b.accent,
        );
        break;
      case GuardianKind.commander:
      case GuardianKind.major:
        // Peaked cap with a star badge.
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.32, h * 0.255, w * 0.36, h * 0.115), Radius.circular(w * 0.045)),
          Paint()..color = b.accent,
        );
        canvas.drawPath(
          Path()
            ..moveTo(w * 0.30, h * 0.365)
            ..quadraticBezierTo(w / 2, h * 0.315, w * 0.70, h * 0.365)
            ..close(),
          Paint()..color = darkHat,
        );
        _drawStar(canvas, Offset(w / 2, h * 0.295), w * 0.05, const Color(0xFFF4E3A1));
        break;
      case GuardianKind.sergeant:
      case GuardianKind.captain:
        // Beret tilted slightly, with a pip.
        canvas.save();
        canvas.translate(w / 2, h * 0.32);
        canvas.rotate(-0.16);
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: w * 0.40, height: h * 0.135), Radius.elliptical(w * 0.20, h * 0.0675)),
          Paint()..color = b.accent,
        );
        canvas.restore();
        canvas.drawCircle(Offset(w * 0.60, h * 0.283), w * 0.03, Paint()..color = const Color(0xFFF4E3A1));
        break;
    }

    // One top highlight so every hat reads as a lit 3D surface.
    canvas.drawOval(Rect.fromLTWH(w * 0.38, h * 0.255, w * 0.10, h * 0.022), topShadow);
  }

  void _drawStar(Canvas canvas, Offset c, double r, Color color) {
    final path = Path();
    for (var i = 0; i < 10; i++) {
      final ang = -math.pi / 2 + i * math.pi / 5;
      final rad = i.isEven ? r : r * 0.44;
      final p = Offset(c.dx + rad * math.cos(ang), c.dy + rad * math.sin(ang));
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _GuardianPainter old) => old.badge != badge;
}
