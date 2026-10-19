import 'dart:ui';

import 'package:flutter/material.dart';

/// Frosted glass: a blurred, translucent panel with a thin light edge. Used only where it earns its place
/// (things that float over other content: the message bar, the tab bar, sheets, the police card, the
/// live-sharing card). Everything else stays flat. With "high contrast" or reduced transparency on, it
/// becomes a solid panel so text stays readable.
class Glass extends StatelessWidget {
  const Glass({super.key, required this.child, this.radius = 20, this.blur = 24, this.padding = EdgeInsets.zero, this.tint});
  final Widget child;
  final double radius;
  final double blur;
  final EdgeInsetsGeometry padding;

  /// Colours the glass (alert red, live green). Kept faint.
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final solid = MediaQuery.of(context).highContrast;
    final base = dark ? const Color(0xFFB9B5FF) : Colors.white;
    final fill = Color.alphaBlend((tint ?? Colors.transparent).withValues(alpha: 0.12), base.withValues(alpha: solid ? (dark ? 0.16 : 1) : (dark ? 0.12 : 0.42)));
    final r = BorderRadius.circular(radius);
    final box = Container(
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: r,
        color: fill,
        border: Border.all(color: Colors.white.withValues(alpha: dark ? 0.26 : 0.85), width: 1.2),
        gradient: solid
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Colors.white.withValues(alpha: dark ? 0.16 : 0.55), Colors.white.withValues(alpha: 0.0)],
              ),
        boxShadow: [BoxShadow(color: const Color(0xFF0E08A3).withValues(alpha: dark ? 0.0 : 0.08), blurRadius: 24, offset: const Offset(0, 8))],
      ),
      child: child,
    );
    if (solid) return ClipRRect(borderRadius: r, child: box);
    return ClipRRect(borderRadius: r, child: BackdropFilter(filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur), child: box));
  }
}

/// Soft indigo and lavender light behind the screen so the glass has something to blur. No green.
class GlassBackdrop extends StatelessWidget {
  const GlassBackdrop({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Stack(children: [
      Positioned.fill(child: ColoredBox(color: dark ? const Color(0xFF0B0B1A) : const Color(0xFFF2F2F7))),
      Positioned(top: -80, right: -60, child: _blob(const Color(0xFF6A5FF0), dark ? 0.55 : 0.42, 320)),
      Positioned(top: 260, left: -120, child: _blob(const Color(0xFF9B8CFF), dark ? 0.36 : 0.36, 300)),
      Positioned(bottom: -60, right: -40, child: _blob(const Color(0xFF3B2FD9), dark ? 0.40 : 0.24, 300)),
      Positioned.fill(child: child),
    ]);
  }

  Widget _blob(Color c, double a, double size) => IgnorePointer(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [c.withValues(alpha: a), c.withValues(alpha: 0)])),
        ),
      );
}
