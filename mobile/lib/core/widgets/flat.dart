import 'package:flutter/material.dart';

import 'brand.dart';
import 'glass.dart';

/// The flat, Apple-style building blocks shared by Messages and Share location.
class Flat {
  static const live = Color(0xFF1FA85B);
  static const danger = Color(0xFFD92D20);
  static Color bg(BuildContext c) => Theme.of(c).brightness == Brightness.dark ? const Color(0xFF0B0B1A) : const Color(0xFFF2F2F7);
  static Color card(BuildContext c) => Theme.of(c).brightness == Brightness.dark ? const Color(0xFF18174D) : Colors.white;
  static Color muted(BuildContext c) => Theme.of(c).colorScheme.onSurface.withValues(alpha: 0.55);
  static Color hairline(BuildContext c) => Theme.of(c).colorScheme.onSurface.withValues(alpha: 0.1);
  static bool still(BuildContext c) => MediaQuery.of(c).disableAnimations;
}

/// A page with a back chevron and a large left-aligned title, on the flat grey background.
class FlatPage extends StatelessWidget {
  const FlatPage({super.key, required this.title, required this.children, this.footer, this.onRefresh, this.subtitle});
  final String title;
  final String? subtitle;
  final List<Widget> children;

  /// Pinned under the list, for the one action the page is about.
  final Widget? footer;
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    final list = ListView(
      physics: const AlwaysScrollableScrollPhysics(),
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
