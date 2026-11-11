import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The app's own profile pictures: 50 flat Sentri faces, men and women, drawn
/// in code (not shipped as photos) so they cost the app nothing and always
/// match the flat look. Every character has their own personality — the face
/// reads a list of traits (glasses, brows, beard, earrings, freckles, smile…)
/// derived from the index, on top of the skin tone, hairstyle and pastel
/// ground. No two of the fifty come out the same. The person picks one in the
/// profile sheet; it stays on this phone like everything else there.
class SentriAvatar extends StatelessWidget {
  const SentriAvatar({super.key, required this.index, this.size = 48});
  final int index;
  final double size;

  @override
  Widget build(BuildContext context) {
    final i = index % SentriAvatarPainter.count;
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: const BoxDecoration(shape: BoxShape.circle),
      child: CustomPaint(painter: SentriAvatarPainter(i)),
    );
  }
}

class SentriAvatarPainter extends CustomPainter {
  SentriAvatarPainter(this.index);
  static const int count = 50;
  final int index;

  static const _skins = [
    Color(0xFFF6D3B8), Color(0xFFE8BC93), Color(0xFFD29A6B), Color(0xFFA9724A), Color(0xFF7A5232),
  ];
  static const _hairDark = [
    Color(0xFF171310), Color(0xFF2A1E14), Color(0xFF3D2A1C), Color(0xFF58361F), Color(0xFF24201C), Color(0xFF4A2E33),
  ];
  static const _grounds = [
    Color(0xFFE5DBFF), Color(0xFFD6E5FA), Color(0xFFDFF3E5), Color(0xFFFCE8D8), Color(0xFFFBE7EF),
    Color(0xFFEDE7F6), Color(0xFFE0F2F1), Color(0xFFF3E5F5), Color(0xFFEFEBE9), Color(0xFFE3F2FD),
  ];
  static const _lip = [
    Color(0xFFC96A5A), Color(0xFFB85C79), Color(0xFFC97B4A), Color(0xFFA65E4E), Color(0xFFD08A7A),
  ];
  static const _bead = [
    Color(0xFFE5A33C), Color(0xFF4C8DD6), Color(0xFF4CAF7D), Color(0xFFD96570), Color(0xFF8D6BD1),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final female = index < 25;
    final j = female ? index : index - 25;
    final skin = _skins[j ~/ 5 % 5];
    final hair = _hairDark[(j * 7 + (female ? 2 : 5)) % 6];
    final ground = _grounds[(j * 3 + 1) % 10];
    final style = j % 5;

    // ---- the personality traits. Modulo arithmetic on different primes, so
    // the fifty mix into fifty distinct people.
    final roundGlasses = j % 4 == 0;
    final squareGlasses = !roundGlasses && j % 9 == 3;
    final oneBrowUp = j % 4 == 2;
    final blush = j % 5 == 2;
    final freckles = j % 6 == 3;
    final mole = j % 8 == 5;
    final grin = j % 3 == 0; // big open smile vs gentle curve
    final smirk = !grin && j % 7 == 4; // a little lopsided smile
    final earring = female && j % 3 == 1;
    final lip = _lip[j % 5];
    final nose = j % 2 == 0;

    final hijab = female && style == 4;
    final bald = !female && style == 3;

    // Male facial hair characters: full beard (the bald one), stubble, goatee,
    // moustache — spread so most men are clean but a few carry facial hair.
    final stubble = !female && !bald && j % 7 == 2;
    final goatee = !female && !bald && j % 5 == 4;
    final moustache = !female && !bald && j % 8 == 1;

    final c = Offset(s / 2, s / 2);
    canvas.drawCircle(c, s / 2, Paint()..color = ground);

    void paint_(Rect r, Color color) => canvas.drawOval(r, Paint()..color = color);
    Rect box(double w, double h, double cy) => Rect.fromCenter(center: Offset(s / 2, cy), width: s * w, height: s * h);

    // Face geometry (hijab keeps a smaller face inside the fabric).
    final faceW = hijab ? 0.30 : 0.42;
    final faceH = hijab ? 0.36 : 0.50;
    final faceY = hijab ? s * 0.50 : s * 0.52;
    final head = box(faceW, faceH, faceY);
    final eyeY = hijab ? s * 0.47 : s * 0.49;
    final eyeDX = hijab ? 0.070 : 0.095;

    // ---- hair / headwear BEHIND the head ----
    if (female && style == 0) {
      // Long straight: big soft panels falling past the jaw.
      paint_(box(0.52, 0.64, s * 0.56), hair);
    } else if (female && style == 1) {
      // Voluminous afro puff above the head.
      canvas.drawCircle(Offset(s / 2, s * 0.33), s * 0.29, Paint()..color = hair);
      canvas.drawCircle(Offset(s * 0.40, s * 0.38), s * 0.10, Paint()..color = hair);
      canvas.drawCircle(Offset(s * 0.60, s * 0.38), s * 0.10, Paint()..color = hair);
    } else if (female && style == 2) {
      // Braids: panels behind + beaded strands each side.
      paint_(box(0.47, 0.58, s * 0.54), hair);
      final bead = _bead[j % 5];
      for (final side in [-1.0, 1.0]) {
        for (var k = 0; k < 3; k++) {
          final x = s / 2 + side * (s * 0.20 + k * s * 0.035);
          final y0 = s * (0.48 + k * 0.02);
          canvas.drawRRect(
            RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(x, y0 + s * 0.12), width: s * 0.055, height: s * 0.26), Radius.circular(s * 0.028)),
            Paint()..color = hair,
          );
          // A coloured bead ends each strand.
          canvas.drawCircle(Offset(x, y0 + s * 0.26), s * 0.026, Paint()..color = bead);
        }
      }
    } else if (female && style == 3) {
      // High bun with a tied band.
      paint_(box(0.52, 0.60, s * 0.55), hair);
      canvas.drawCircle(Offset(s / 2, s * 0.20), s * 0.10, Paint()..color = hair);
      canvas.drawCircle(Offset(s / 2, s * 0.20), s * 0.10, Paint()..style = PaintingStyle.stroke..strokeWidth = s * 0.02..color = _bead[(j + 2) % 5]);
    } else if (hijab) {
      // The hood, with a thin trim band that gives it craft.
      paint_(box(0.62, 0.66, s * 0.53), _fabrics2(j));
      canvas.drawOval(box(0.62, 0.66, s * 0.53), Paint()..style = PaintingStyle.stroke..strokeWidth = s * 0.02..color = _bead[j % 5].withValues(alpha: 0.6));
    } else if (!female && style == 2) {
      // Medium afro with a clean edge.
      canvas.drawCircle(Offset(s / 2, s * 0.35), s * 0.28, Paint()..color = hair);
      canvas.drawCircle(Offset(s / 2, s * 0.35), s * 0.28, Paint()..style = PaintingStyle.stroke..strokeWidth = s * 0.018..color = ground.withValues(alpha: 0.35));
    } else if (!female && style == 4) {
      // Locs behind the head, tipped lighter.
      paint_(box(0.52, 0.58, s * 0.54), hair);
      for (final side in [-1.0, 1.0]) {
        for (var k = 0; k < 3; k++) {
          final x = s / 2 + side * (s * 0.21 + k * s * 0.03);
          final y0 = s * (0.42 + k * 0.05);
          canvas.drawCircle(Offset(x, y0), s * 0.032, Paint()..color = hair);
          canvas.drawCircle(Offset(x, y0 + s * 0.045), s * 0.02, Paint()..color = hair.withValues(alpha: 0.75));
        }
      }
    }

    // A soft hair sheen so flat hair still feels alive (skip hood + bald).
    if (!hijab && !bald) {
      final sheen = Paint()
        ..color = Colors.white.withValues(alpha: 0.14)
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.035
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(box(faceW + 0.02, faceH + 0.06, faceY - s * 0.05), 1.05 * math.pi, 0.55 * math.pi, false, sheen);
    }

    // ---- the head ----
    paint_(head, skin);

    // Hair rim + fringe on top (not for hood, bald, or full-afro styles).
    if (!hijab && !bald && !(female && style == 1) && !(!female && style == 2)) {
      paint_(box(faceW + 0.01, faceH + 0.03, faceY - s * 0.05), hair);
      final fringe = Paint()
        ..color = hair
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.055
        ..strokeCap = StrokeCap.round;
      final fy = faceY - faceH * s * 0.30;
      canvas.drawLine(Offset(s / 2 - faceW * s * 0.30, fy), Offset(s / 2 + faceW * s * 0.30, fy), fringe);
    }

    // ---- facial hair for the men ----
    if (bald) {
      final beard = Paint()
        ..color = hair
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.085
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(head, 0.10 * math.pi, 0.80 * math.pi, false, beard);
      // Moustache over the beard line.
      final mo = Paint()..color = hair..strokeWidth = s * 0.045..strokeCap = StrokeCap.round..style = PaintingStyle.stroke;
      canvas.drawLine(Offset(s / 2 - s * 0.055, eyeY + s * 0.105), Offset(s / 2 + s * 0.055, eyeY + s * 0.105), mo);
    } else if (stubble) {
      // Dotted jaw shadow.
      final dot = Paint()..color = hair.withValues(alpha: 0.35);
      for (var k = 0; k < 7; k++) {
        final a = 0.28 * math.pi + k * (0.44 * math.pi / 6);
        canvas.drawCircle(Offset(s / 2 + (faceW * s / 2 - s * 0.03) * math.cos(a), faceY + (faceH * s / 2 - s * 0.03) * math.sin(a) + s * 0.01), s * 0.014, dot);
      }
    } else if (goatee) {
      final go = Paint()..color = hair;
      canvas.drawOval(Rect.fromCenter(center: Offset(s / 2, faceY + faceH * s * 0.34), width: s * 0.10, height: s * 0.10), go);
      final mo = Paint()..color = hair..strokeWidth = s * 0.04..strokeCap = StrokeCap.round..style = PaintingStyle.stroke;
      canvas.drawLine(Offset(s / 2 - s * 0.05, eyeY + s * 0.105), Offset(s / 2 + s * 0.05, eyeY + s * 0.105), mo);
    } else if (moustache) {
      final mo = Paint()..color = hair..strokeWidth = s * 0.05..strokeCap = StrokeCap.round..style = PaintingStyle.stroke;
      canvas.drawLine(Offset(s / 2 - s * 0.06, eyeY + s * 0.105), Offset(s / 2 + s * 0.06, eyeY + s * 0.105), mo);
    }

    // ---- brows: two moods ----
    final brow = Paint()
      ..color = hair
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.026
      ..strokeCap = StrokeCap.round;
    final browY = eyeY - s * 0.062;
    for (final side in [-1.0, 1.0]) {
      final bx = s / 2 + side * s * eyeDX;
      // One raised brow gives the curious face; flat brows give the calm one.
      final lift = oneBrowUp && side > 0 ? -s * 0.028 : (oneBrowUp && side < 0 ? s * 0.012 : 0.0);
      canvas.drawLine(Offset(bx - s * 0.045, browY + lift), Offset(bx + s * 0.045, browY + lift - s * 0.012), brow);
    }

    // ---- eyes ----
    final ink = Paint()..color = const Color(0xFF20242B);
    for (final side in [-1.0, 1.0]) {
      canvas.drawOval(
        box(0.045, 0.06, eyeY).shift(Offset(side * s * eyeDX, 0)),
        ink,
      );
      // A tiny light spark in each eye keeps them friendly.
      canvas.drawCircle(Offset(s / 2 + side * s * eyeDX - s * 0.008, eyeY - s * 0.008), s * 0.012, Paint()..color = Colors.white);
    }

    // ---- nose (a soft little L) ----
    if (nose) {
      final nz = Paint()
        ..color = const Color(0xFF20242B).withValues(alpha: 0.45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.018
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(s / 2, eyeY + s * 0.03), Offset(s / 2, eyeY + s * 0.075), nz);
      canvas.drawLine(Offset(s / 2, eyeY + s * 0.075), Offset(s / 2 + s * 0.02, eyeY + s * 0.082), nz);
    }

    // ---- blush, freckles, mole ----
    if (blush) {
      final bl = Paint()..color = const Color(0xFFE58B8B).withValues(alpha: 0.45);
      for (final side in [-1.0, 1.0]) {
        canvas.drawCircle(Offset(s / 2 + side * s * (eyeDX + 0.055), eyeY + s * 0.075), s * 0.038, bl);
      }
    }
    if (freckles) {
      final fr = Paint()..color = const Color(0xFF20242B).withValues(alpha: 0.30);
      for (final side in [-1.0, 1.0]) {
        for (var k = 0; k < 3; k++) {
          canvas.drawCircle(Offset(s / 2 + side * (s * (eyeDX + 0.03) + k * s * 0.02), eyeY + s * 0.075 + (k % 2) * s * 0.02), s * 0.008, fr);
        }
      }
    }
    if (mole) {
      canvas.drawCircle(Offset(s / 2 + s * (faceW * 0.28), eyeY + s * 0.11), s * 0.012, Paint()..color = const Color(0xFF20242B).withValues(alpha: 0.55));
    }

    // ---- mouth: three moods ----
    final mouth = Paint()
      ..color = female ? lip.withValues(alpha: 0.9) : const Color(0xFF20242B)
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.024
      ..strokeCap = StrokeCap.round;
    final my = eyeY + s * 0.135;
    if (grin) {
      // A big open grin with a little fill.
      final grinRect = Rect.fromCenter(center: Offset(s / 2, my + s * 0.012), width: s * 0.15, height: s * 0.11);
      final fill = Path()
        ..addArc(grinRect, 0.08 * math.pi, 0.84 * math.pi)
        ..close();
      canvas.drawPath(fill, Paint()..color = (female ? lip : const Color(0xFF20242B)).withValues(alpha: 0.85));
      canvas.drawArc(grinRect, 0.08 * math.pi, 0.84 * math.pi, false, mouth);
    } else if (smirk) {
      canvas.drawArc(Rect.fromCenter(center: Offset(s / 2 + s * 0.02, my), width: s * 0.13, height: s * 0.09), 0.02 * math.pi, 0.55 * math.pi, false, mouth);
    } else {
      canvas.drawArc(Rect.fromCenter(center: Offset(s / 2, my), width: s * 0.13, height: s * 0.10), 0.10 * math.pi, 0.30 * math.pi, false, mouth);
    }

    // ---- glasses ----
    if (roundGlasses || squareGlasses) {
      final g = Paint()
        ..color = const Color(0xFF20242B).withValues(alpha: 0.75)
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.02;
      for (final side in [-1.0, 1.0]) {
        final cx = s / 2 + side * s * eyeDX;
        final cy = eyeY;
        final r = Rect.fromCenter(center: Offset(cx, cy), width: s * (roundGlasses ? 0.115 : 0.12), height: s * (roundGlasses ? 0.115 : 0.095));
        if (roundGlasses) {
          canvas.drawCircle(Offset(cx, cy), s * 0.058, g);
        } else {
          canvas.drawRRect(RRect.fromRectAndRadius(r, Radius.circular(s * 0.015)), g);
        }
      }
      canvas.drawLine(Offset(s / 2 - s * eyeDX + s * 0.058, eyeY), Offset(s / 2 + s * eyeDX - s * 0.058, eyeY), g);
    }

    // ---- earrings ----
    if (earring) {
      final e = Paint()..color = _bead[(j + 1) % 5];
      for (final side in [-1.0, 1.0]) {
        canvas.drawCircle(Offset(s / 2 + side * (faceW * s / 2 - s * 0.012), faceY + s * 0.02), s * 0.02, e);
      }
    }
  }

  /// Hijab fabric: a rotating palette so the hood colours differ too.
  static Color _fabrics2(int j) {
    const f = [
      Color(0xFF5C4D7D), Color(0xFF3E5C76), Color(0xFF71413C), Color(0xFF2F4550), Color(0xFF6B5B95),
      Color(0xFF31695A), Color(0xFF8A4E85), Color(0xFF40518B),
    ];
    return f[j % f.length];
  }

  @override
  bool shouldRepaint(SentriAvatarPainter oldDelegate) => oldDelegate.index != index;
}
