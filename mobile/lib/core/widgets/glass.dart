import 'package:flutter/material.dart';

import '../theme.dart';

/// A flat, solid rounded panel where frosted glass used to be. The API stays the same
/// so every place that lifts a [Glass] (the message bar, the tab bar, sheets, the
/// police card, the live-sharing card) simply becomes flat and solid — nothing is
/// translucent and nothing is blurred, so text stays readable on any wallpaper,
/// including "high contrast" mode, with no blur cost on a cheap phone.
class Glass extends StatelessWidget {
  const Glass({super.key, required this.child, this.radius = 20, this.blur = 24, this.padding = EdgeInsets.zero, this.tint});
  final Widget child;
  final double radius;
  final double blur;
  final EdgeInsetsGeometry padding;

  /// Colours the panel faintly (alert red, live green).
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base = dark ? SentriColors.cardDark : Colors.white;
    final fill = Color.alphaBlend((tint ?? Colors.transparent).withValues(alpha: 0.10), base);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        color: fill,
        boxShadow: [BoxShadow(color: const Color(0xFF0E08A3).withValues(alpha: dark ? 0.0 : 0.05), blurRadius: 12, offset: const Offset(0, 4))],
      ),
      child: child,
    );
  }
}

/// The page background. Every page and sheet in the app sits on the same soft
/// wash of brand colour - the cool indigo/mint/amber blend Vic picked for the
/// emergency panel, in dark and in a tuned light version - instead of a dead
/// flat grey, so no part of the app ever feels like a different app.
class GlassBackdrop extends StatelessWidget {
  const GlassBackdrop({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Stack(children: [
      Positioned.fill(
        child: DecoratedBox(
          decoration: BoxDecoration(color: dark ? SentriColors.surfaceDark : SentriColors.surfaceLight),
          child: CustomPaint(painter: WashPainter(dark: dark)),
        ),
      ),
      Positioned.fill(child: child),
    ]);
  }
}
