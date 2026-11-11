import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';
import 'brand.dart';
import 'glass.dart';

/// A tap target that "gets excited" when pressed, like the reference reel: the
/// child does a quick squash-jump with a tiny happy wiggle and settles back.
/// Give it [onTap] and it also handles the tap itself, or leave it null and
/// trigger the excitement separately with the [state] handle.
class TapBounce extends StatefulWidget {
  const TapBounce({super.key, required this.child, this.onTap, this.jump = 5, this.wiggle = 0.07});
  final Widget child;
  final VoidCallback? onTap;

  /// How high the child hops, in logical pixels.
  final double jump;

  /// How far it wiggles left-right, in radians.
  final double wiggle;

  @override
  State<TapBounce> createState() => TapBounceState();
}

class TapBounceState extends State<TapBounce> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 480));

  /// Fires the excitement without a tap (used by widgets that animate on other
  /// events too).
  void excite() => _c.forward(from: 0);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).disableAnimations) return GestureDetector(behavior: HitTestBehavior.opaque, onTap: widget.onTap, child: widget.child);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        excite();
        widget.onTap?.call();
      },
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) {
          // One squash-jump hop plus two little shakes: the "excited pet" move.
          final t = _c.value;
          final hop = math.sin(math.pi * t);
          final shake = math.sin(math.pi * 4 * t) * (1 - t);
          return Transform.translate(
            offset: Offset(0, -widget.jump * hop),
            child: Transform.rotate(
              angle: widget.wiggle * shake,
              child: Transform.scale(scale: 1 - 0.10 * hop, child: child),
            ),
          );
        },
        child: widget.child,
      ),
    );
  }
}

/// The flat, Apple-style building blocks shared by Messages and Share location.
class Flat {
  static const live = Color(0xFF1FA85B);
  static const danger = Color(0xFFD92D20);
  static Color bg(BuildContext c) => Theme.of(c).brightness == Brightness.dark ? SentriColors.surfaceDark : SentriColors.surfaceLight;
  static Color card(BuildContext c) => Theme.of(c).brightness == Brightness.dark ? SentriColors.cardDark : Colors.white;
  static Color muted(BuildContext c) => Theme.of(c).colorScheme.onSurface.withValues(alpha: 0.55);
  static Color hairline(BuildContext c) => Theme.of(c).colorScheme.onSurface.withValues(alpha: 0.1);
  static bool still(BuildContext c) => MediaQuery.of(c).disableAnimations;
}

/// A page with a back chevron and a large left-aligned title, on the flat grey background.
/// [physics] may loosen the scroll (bouncy pull), and [onScroll] reports the offset so
/// pages with a photo banner can slide it (parallax).
class FlatPage extends StatelessWidget {
  const FlatPage({super.key, required this.title, required this.children, this.footer, this.onRefresh, this.subtitle, this.physics, this.onScroll});
  final String title;
  final String? subtitle;
  final List<Widget> children;

  /// Pinned under the list, for the one action the page is about.
  final Widget? footer;
  final Future<void> Function()? onRefresh;

  /// Scroll physics override; the default keeps ordinary pages always scrollable.
  final ScrollPhysics? physics;

  /// Called with the list's scroll offset whenever it changes.
  final void Function(double offset)? onScroll;

  @override
  Widget build(BuildContext context) {
    final list = NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (onScroll != null && n.metrics.axis == Axis.vertical) {
          onScroll!(n.metrics.pixels);
        }
        return false;
      },
      child: ListView(
        // The springy feel from the reference reel, app-wide: always bouncy,
        // and with the faster deceleration the settle-back has that lively
        // elastic snap instead of a long glide.
        physics: physics ?? const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics(decelerationRate: ScrollDecelerationRate.fast)),
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
        children: [
          Text(title, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700, letterSpacing: -0.5, height: 1.1)),
          if (subtitle != null) ...[
            const SizedBox(height: 8),
            Text(subtitle!, style: TextStyle(fontSize: 15, height: 1.4, color: Flat.muted(context))),
          ],
          const SizedBox(height: 22),
          ...children,
        ],
      ),
    );
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GlassBackdrop(child: SafeArea(
        child: Column(children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: TextButton.icon(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back_ios_new, size: 16),
                label: const Text('Back', style: TextStyle(fontSize: 16)),
                style: TextButton.styleFrom(foregroundColor: Brand.indigoHi),
              ),
            ),
          ),
          Expanded(child: onRefresh == null ? list : RefreshIndicator(onRefresh: onRefresh!, child: list)),
          if (footer != null) Padding(padding: const EdgeInsets.fromLTRB(20, 8, 20, 16), child: footer),
        ]),
      )),
    );
  }
}

/// White rounded group with hairline dividers between rows.
class FlatGroup extends StatelessWidget {
  const FlatGroup({super.key, required this.children, this.header});
  final List<Widget> children;
  final String? header;
  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (header != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(header!, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Flat.muted(context))),
        ),
      Glass(
        radius: 16,
        child: Column(children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) Divider(height: 0.5, thickness: 0.5, indent: 16, color: Flat.hairline(context)),
            children[i],
          ],
        ]),
      ),
    ]);
  }
}

/// A round person glyph. Contacts have no names on this phone, so it shows a calm silhouette.
class FlatAvatar extends StatelessWidget {
  const FlatAvatar({super.key, this.size = 40, this.on = false, this.letter});
  final double size;
  final bool on;
  final String? letter;
  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: on ? Brand.indigo : Flat.hairline(context)),
      alignment: Alignment.center,
      child: letter != null
          ? Text(letter!, style: TextStyle(fontSize: size * 0.42, fontWeight: FontWeight.w600, color: on ? Colors.white : null))
          : Icon(Icons.person, size: size * 0.55, color: on ? Colors.white : Flat.muted(context)),
    );
  }
}

/// A dot that breathes while something is live. Still when the system asks for reduced motion.
class LiveDot extends StatefulWidget {
  const LiveDot({super.key, this.size = 10, this.color = Flat.live});
  final double size;
  final Color color;
  @override
  State<LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<LiveDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Flat.still(context)) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return SizedBox(
      width: s * 2.6,
      height: s * 2.6,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Stack(alignment: Alignment.center, children: [
          Container(
            width: s * (1 + 1.6 * _c.value),
            height: s * (1 + 1.6 * _c.value),
            decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color.withValues(alpha: 0.28 * (1 - _c.value))),
          ),
          Container(width: s, height: s, decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color)),
        ]),
      ),
    );
  }
}

/// The face the home and SOS screens wear: big vertical eyes and a smile in the
/// same language as the reference boards. [hold] is 0 calm — a wide open smile —
/// and 1 when the SOS is held or triggered, where the smile sets into a knowing
/// smirk with the right corner lifted (never an angry frown). [blink] is 0 with
/// the eyes open and 1 shut; the home screen drives it so the face blinks every
/// two seconds and feels alive.
class MoodFacePainter extends CustomPainter {
  const MoodFacePainter(this.hold, this.ink, {this.blink = 0});
  /// 0 = calm, 1 = the SOS hold is nearly done (or the alert is live).
  final double hold;
  final Color ink;

  /// 0 = eyes open, 1 = eyes shut for this frame.
  final double blink;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide / 2;
    final c = Offset(size.width / 2, size.height / 2);
    final eye = Paint()..color = ink;
    // Two big eyes: vertical rounded bars, sitting on the upper half like the reference.
    // They stretch a touch while holding, and shut smoothly on a blink.
    final stretch = 1.0 + 0.25 * hold;
    for (final side in [-1.0, 1.0]) {
      final ex = c.dx + side * r * 0.40;
      final ey = c.dy - r * 0.18;
      final ew = r * 0.155 * (1.0 + 0.35 * hold);
      final eh = r * 0.26 * stretch * (1.0 - blink);
      if (eh <= 0) continue;
      final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(ex, ey), width: ew * 2, height: eh * 2),
        Radius.circular(ew),
      );
      canvas.drawRRect(rect, eye);
    }
    // The mouth: a wide smile when safe; while holding (or with the alert on) it
    // settles into a smirk, the right corner lifted - a knowing face, not anger.
    final mouth = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.07
      ..strokeCap = StrokeCap.round;
    final mw = r * 0.62;
    final my = c.dy + r * 0.26;
    if (hold < 0.5) {
      final path = Path()
        ..moveTo(c.dx - mw / 2, my)
        ..quadraticBezierTo(c.dx, my + r * (0.30 - 0.34 * hold * 2), c.dx + mw / 2, my);
      canvas.drawPath(path, mouth);
    } else {
      final k = (hold - 0.5) * 2;
      final path = Path()
        ..moveTo(c.dx - mw / 2, my + r * 0.02 * k)
        ..quadraticBezierTo(c.dx + mw * 0.08, my + r * 0.08 * k, c.dx + mw / 2, my - r * 0.20 * k);
      canvas.drawPath(path, mouth);
    }
  }

  @override
  bool shouldRepaint(MoodFacePainter oldDelegate) =>
      oldDelegate.hold != hold || oldDelegate.ink != ink || oldDelegate.blink != blink;
}

/// Solid full-width action. [danger] is for stopping something.
class FlatButton extends StatelessWidget {
  const FlatButton({super.key, required this.label, required this.onPressed, this.danger = false, this.quiet = false});
  final String label;
  final VoidCallback? onPressed;
  final bool danger;

  /// Tinted instead of solid, for the second action on a page.
  final bool quiet;
  @override
  Widget build(BuildContext context) {
    final base = danger ? Flat.danger : Brand.indigo;
    return Opacity(
      opacity: onPressed == null ? 0.4 : 1,
      child: Material(
        color: quiet ? base.withValues(alpha: 0.1) : base,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onPressed,
          child: Container(
            height: 54,
            alignment: Alignment.center,
            child: Text(label, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: quiet ? (danger ? Flat.danger : Brand.indigoHi) : Colors.white)),
          ),
        ),
      ),
    );
  }
}
