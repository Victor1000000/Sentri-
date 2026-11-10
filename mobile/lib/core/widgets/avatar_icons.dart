import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The app's own profile pictures: 50 flat Sentri faces, men and women, drawn
/// in code (not shipped as photos) so they cost the app nothing and always
/// match the flat look. Five skin tones, ten hairstyles (five women, five men)
/// and ten pastel grounds mix into 50 guaranteed-distinct icons. The person
/// picks one in the profile sheet; it stays on this phone like everything else.
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
    Color(0xFFF2CCB0), Color(0xFFE5B98E), Color(0xFFCE9163), Color(0xFFA26B42), Color(0xFF6E4B2A),
  ];
  static const _hairs = [
    Color(0xFF1E1611), Color(0xFF35241A), Color(0xFF4E3427), Color(0xFF6B3F2E), Color(0xFF23201D),
  ];
  static const _fabrics = [
    Color(0xFF5C4D7D), Color(0xFF3E5C76), Color(0xFF71413C), Color(0xFF2F4550), Color(0xFF6B5B95),
  ];
  static const _grounds = [
    Color(0xFFE5DBFF), Color(0xFFD6E5FA), Color(0xFFDFF3E5), Color(0xFFFCE8D8), Color(0xFFFBE7EF),
    Color(0xFFEDE7F6), Color(0xFFE0F2F1), Color(0xFFF3E5F5), Color(0xFFEFEBE9), Color(0xFFE3F2FD),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final c = Offset(s / 2, s / 2);
    final female = index < 25;
    final j = female ? index : index - 25;
    final skin = _skins[j ~/ 5 % 5];
    final style = j % 5;
    final hair = _hairs[(j % 5 + j ~/ 5) % 5];
    final hijab = female && style == 4;
    final bald = !female && style == 3;

    final ground = _grounds[j % 10];
    canvas.drawCircle(c, s / 2, Paint()..color = ground);

    // Draw order: hair volume behind the head, the head itself, the parts that
    // sit ON the head, then the calm little face.
    void oval(Rect r, Color color) => canvas.drawOval(r, Paint()..color = color);
    Rect headRect(double w, double h, double cy) =>
        Rect.fromCenter(center: Offset(s / 2, cy), width: s * w, height: s * h);
    final faceW = hijab ? 0.30 : 0.42;
    final faceH = hijab ? 0.36 : 0.50;
    final faceY = hijab ? s * 0.50 : s * 0.52;
    final head = headRect(faceW, faceH, faceY);

    if (female && style == 0) {
      oval(headRect(0.50, 0.62, s * 0.56), hair); // long straight panels
    } else if (female && style == 1) {
      canvas.drawCircle(Offset(s / 2, s * 0.34), s * 0.28, Paint()..color = hair); // afro puff
    } else if (female && style == 2) {
      oval(headRect(0.46, 0.56, s * 0.54), hair); // braids behind + strands below
      for (final side in [-1.0, 1.0]) {
        for (var k = 0; k < 3; k++) {
          final x = s / 2 + side * (s * 0.20 + k * s * 0.035);
          final y0 = s * (0.48 + k * 0.02);
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(center: Offset(x, y0 + s * 0.12), width: s * 0.055, height: s * 0.26),
              Radius.circular(s * 0.028),
            ),
            Paint()..color = hair,
          );
        }
      }
    } else if (female && style == 3) {
      oval(headRect(0.52, 0.60, s * 0.55), hair); // swept hair + high bun above
      canvas.drawCircle(Offset(s / 2, s * 0.20), s * 0.10, Paint()..color = hair);
    } else if (hijab) {
      oval(headRect(0.62, 0.66, s * 0.53), _fabrics[j ~/ 5 % 5]); // the hood
    } else if (!female && style == 2) {
      canvas.drawCircle(Offset(s / 2, s * 0.36), s * 0.27, Paint()..color = hair); // medium afro
    } else if (!female && style == 4) {
      oval(headRect(0.52, 0.58, s * 0.54), hair); // locs behind the head
    }

    if (!hijab && !bald) {
      oval(headRect(faceW + 0.01, faceH + 0.03, faceY - s * 0.05), hair); // rim above the head
    }

    oval(head, skin);

    if (!hijab && !bald) {
      // A fringe line, so the rim reads as hair, not a halo.
      final fringe = Paint()
        ..color = hair
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.055
        ..strokeCap = StrokeCap.round;
      final fy = faceY - faceH * s * 0.30;
      canvas.drawLine(Offset(s / 2 - faceW * s * 0.30, fy), Offset(s / 2 + faceW * s * 0.30, fy), fringe);
    }

    if (bald) {
      final beard = Paint()
        ..color = hair
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.085
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(head, 0.10 * math.pi, 0.80 * math.pi, false, beard);
    }

    // The calm face the app wears everywhere: two dark eyes, a light smile.
    final ink = Paint()..color = const Color(0xFF20242B);
    final eyeY = hijab ? s * 0.47 : s * 0.49;
    for (final side in [-1.0, 1.0]) {
      canvas.drawOval(
        headRect(0.045, 0.06, eyeY).shift(Offset(side * s * (hijab ? 0.07 : 0.095), 0)),
        ink,
      );
    }
    final mouth = Paint()
      ..color = const Color(0xFF20242B)
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.022
      ..strokeCap = StrokeCap.round;
    final my = hijab ? s * 0.60 : s * 0.63;
    canvas.drawArc(
      Rect.fromCenter(center: Offset(s / 2, my), width: s * 0.13, height: s * 0.10),
      0.10 * math.pi, 0.30 * math.pi, false, mouth,
    );
  }

  @override
  bool shouldRepaint(SentriAvatarPainter oldDelegate) => oldDelegate.index != index;
}
