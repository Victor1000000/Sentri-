import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../theme.dart';
import 'glass.dart';

/// Brand colours of the indigo / lavender look. SOS red stays in [SentriColors].
class Brand {
  static const indigo = Color(0xFF0E08A3);
  static const indigoHi = Color(0xFF6A5FF0);
  static const indigoDeep = Color(0xFF15106F);
  static const mint = Color(0xFF13FF47);
  static const lavender = Color(0xFFAAA6F8);
  static const splash = Color(0xFF0D0A9C);
}

/// The S mark: a circle cut by three slanted stripes. Drawn in code so it needs no asset.
class SentriMark extends StatelessWidget {
  const SentriMark({super.key, this.size = 34, this.color = Brand.indigo});
  final double size;
  final Color color;
  @override
  Widget build(BuildContext context) => SizedBox.square(dimension: size, child: CustomPaint(painter: _MarkPainter(color)));
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size s) {
    final k = s.width / 100;
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromLTWH(0, 0, s.width, s.height)));
    Path poly(List<List<double>> p) {
      final path = Path()..moveTo(p[0][0] * k, p[0][1] * k);
      for (final q in p.skip(1)) {
        path.lineTo(q[0] * k, q[1] * k);
      }
      return path..close();
    }
    final paint = Paint()..color = color;
    canvas.drawPath(poly([[0, 0], [100, 0], [100, 17], [0, 23]]), paint);
    canvas.drawPath(poly([[0, 28], [100, 41], [100, 69], [0, 53]]), paint);
    canvas.drawPath(poly([[0, 100], [0, 87], [100, 74], [100, 100]]), paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MarkPainter o) => o.color != color;
}

/// The neon-green mark on a rounded indigo tile. This is the logo everywhere inside the app, so the green
/// always has the indigo behind it and stays visible on light and dark screens.
class SentriLogoTile extends StatelessWidget {
  const SentriLogoTile({super.key, this.size = 40});
  final double size;
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        padding: EdgeInsets.all(size * 0.17),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * 0.3),
          gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Brand.indigoHi, Brand.indigo, Brand.indigoDeep], stops: [0, 0.45, 1]),
          boxShadow: [BoxShadow(color: Brand.indigo.withValues(alpha: 0.28), blurRadius: 14, offset: const Offset(0, 5))],
        ),
        child: const SentriMark(color: Brand.mint),
      );
}

class SentriWordmark extends StatelessWidget {
  const SentriWordmark({super.key, this.size = 28, this.color = Brand.indigo});
  final double size;
  final Color color;
  @override
  Widget build(BuildContext context) =>
      Text('Sentri', style: TextStyle(fontSize: size, fontWeight: FontWeight.w500, letterSpacing: -size * 0.035, height: 1, color: color));
}

/// Indigo splash with the green mark and white wordmark.
class SplashView extends StatelessWidget {
  const SplashView({super.key});
  @override
  Widget build(BuildContext context) => const ColoredBox(
        color: Brand.splash,
        child: Center(
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            SentriMark(size: 60, color: Brand.mint),
            SizedBox(width: 12),
            SentriWordmark(size: 50, color: Colors.white),
          ]),
        ),
      );
}

/// Soft lavender gradient used behind every screen.
class SentriBackground extends StatelessWidget {
  const SentriBackground({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final top = dark ? const Color(0xFF171452) : const Color(0xFFDDDBFF);
    final mid = dark ? const Color(0xFF0D0C2E) : Colors.white;
    final bot = dark ? const Color(0xFF131146) : const Color(0xFFE5E5FF);
    return DecoratedBox(
      decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [top, bot])),
      child: DecoratedBox(
        decoration: BoxDecoration(gradient: RadialGradient(center: const Alignment(0, 0.0), radius: 0.9, colors: [mid, mid.withValues(alpha: 0)])),
        child: Stack(children: [
          Positioned(top: -90, right: -70, child: IgnorePointer(child: Container(width: 320, height: 320, decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [Brand.indigoHi.withValues(alpha: dark ? 0.5 : 0.32), Brand.indigoHi.withValues(alpha: 0)]))))),
          Positioned(bottom: -80, left: -90, child: IgnorePointer(child: Container(width: 300, height: 300, decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [const Color(0xFF9B8CFF).withValues(alpha: dark ? 0.35 : 0.3), const Color(0xFF9B8CFF).withValues(alpha: 0)]))))),
          Positioned.fill(child: child),
        ]),
      ),
    );
  }
}

/// Logo top-left, round translate button top-right. Tapping it opens the language sheet.
class SentriTopBar extends StatelessWidget {
  const SentriTopBar({super.key, required this.i18n, required this.onLanguage, this.onLogoTap, this.compact = false});
  final bool compact;
  final I18n i18n;
  final Future<void> Function(String code) onLanguage;
  final VoidCallback? onLogoTap;

  @override
  Widget build(BuildContext context) {
    // Light mode: black mark and black wordmark. Dark mode: neon-green mark and white wordmark.
    final dark = Theme.of(context).brightness == Brightness.dark;
    final markColor = dark ? Brand.mint : Colors.black;
    final wordColor = dark ? Colors.white : Colors.black;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          GestureDetector(
            onTap: onLogoTap,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SentriMark(size: compact ? 30 : 38, color: markColor),
              const SizedBox(height: 4),
              SentriWordmark(size: compact ? 19 : 24, color: wordColor),
            ]),
          ),
          Row(mainAxisSize: MainAxisSize.min, children: [
          const ThemeButton(),
          SizedBox(width: compact ? 8 : 10),
          Semantics(
            button: true,
            label: i18n.t('lang.title'),
            child: Material(
              color: compact ? (Theme.of(context).brightness == Brightness.dark ? const Color(0xFF18174D) : Colors.white) : Brand.indigo,
              shape: CircleBorder(side: compact ? BorderSide(color: Colors.black.withValues(alpha: 0.12)) : BorderSide.none),
              elevation: compact ? 0 : 4,
              shadowColor: Brand.indigo.withValues(alpha: 0.4),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => unawaited(showLanguageSheet(context, i18n, onLanguage)),
                child: SizedBox(width: compact ? 38 : 46, height: compact ? 38 : 46, child: Icon(Icons.translate, color: compact ? Brand.indigo : Colors.white, size: compact ? 20 : 24)),
              ),
            ),
          ),
          ]),
        ],
      ),
    );
  }
}

Future<void> showLanguageSheet(BuildContext context, I18n i18n, Future<void> Function(String) onPick) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    elevation: 0,
    builder: (ctx) => Glass(
      radius: 30,
      blur: 28,
      child: SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 0, 22, 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(i18n.t('lang.title'), style: Theme.of(ctx).textTheme.titleMedium),
          const SizedBox(height: 12),

          for (final l in supportedLanguages)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _LangOption(
                label: l.nativeName,
                code: l.code.toUpperCase(),
                selected: l.code == i18n.code,
                onTap: () async {
                  Navigator.pop(ctx);
                  await onPick(l.code);
                },
              ),
            ),
        ]),
      ),
    )),
  );
}

/// One tap flips light and dark, right beside the language button on every screen that has the top bar.
class ThemeButton extends StatelessWidget {
  const ThemeButton({super.key});
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      button: true,
      label: dark ? 'Light mode' : 'Dark mode',
      child: Material(
        color: dark ? const Color(0xFF18174D) : Colors.white,
        shape: CircleBorder(side: BorderSide(color: (dark ? Colors.white : Colors.black).withValues(alpha: 0.14))),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => unawaited(ThemeChoice.set(dark ? ThemeMode.light : ThemeMode.dark)),
          child: SizedBox(width: 38, height: 38, child: Icon(dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined, size: 20, color: dark ? Colors.white : Colors.black)),
        ),
      ),
    );
  }
}

class _LangOption extends StatelessWidget {
  const _LangOption({required this.label, required this.code, required this.selected, required this.onTap});
  final String label, code;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    return InkWell(
      borderRadius: BorderRadius.circular(30),
      onTap: onTap,
      child: Ink(
        height: 50,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(30),
          gradient: selected ? gradientFill : null,
          border: selected ? null : Border.all(color: ink, width: 2.5),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label, style: TextStyle(fontSize: 16, color: selected ? Colors.white : ink)),
          Text(code, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: selected ? Colors.white70 : ink.withValues(alpha: 0.6))),
        ]),
      ),
    );
  }
}

const gradientFill = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [Brand.indigoHi, Brand.indigo, Brand.indigoDeep],
  stops: [0, 0.4, 1],
);

/// Primary action: glossy indigo pill with a lavender halo.
class PillButton extends StatelessWidget {
  const PillButton({super.key, required this.label, required this.onPressed});
  final String label;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Container(
        height: 58,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: Brand.lavender.withValues(alpha: 0.75), width: 3),
          gradient: gradientFill,
          boxShadow: [BoxShadow(color: Brand.indigo.withValues(alpha: 0.25), blurRadius: 20, offset: const Offset(0, 10))],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(27),
            onTap: onPressed,
            child: Center(child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w500))),
          ),
        ),
      ),
    );
  }
}

/// Outlined pill button (e.g. "+ Add Contact", menu rows).
class OutlinePill extends StatelessWidget {
  const OutlinePill({super.key, required this.label, required this.onPressed, this.trailing});
  final String label;
  final VoidCallback onPressed;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    return InkWell(
      borderRadius: BorderRadius.circular(30),
      onTap: onPressed,
      child: Ink(
        height: 54,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(30), border: Border.all(color: ink, width: 2.5)),
        child: Row(
          mainAxisAlignment: trailing == null ? MainAxisAlignment.center : MainAxisAlignment.spaceBetween,
          children: [Text(label, style: const TextStyle(fontSize: 17)), if (trailing != null) trailing!],
        ),
      ),
    );
  }
}

/// Pill input with a thick outline and an optional label above it.
class PillField extends StatelessWidget {
  const PillField({super.key, required this.controller, this.label, this.hint, this.keyboardType, this.obscure = false, this.maxLength, this.autofillHints, this.noAutofill = false, this.focusNode});
  final TextEditingController controller;
  final String? label, hint;
  final TextInputType? keyboardType;
  final bool obscure;
  final int? maxLength;
  final Iterable<String>? autofillHints;

  /// Switches the phone's autofill off for this box. Used where several boxes sit together and each must
  /// be typed on its own (emergency contacts), so autofill can't fill them all with one number.
  final bool noAutofill;
  final FocusNode? focusNode;
  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    final border = OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: BorderSide(color: ink, width: 2.5));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (label != null) Padding(padding: const EdgeInsets.only(left: 6, bottom: 6), child: Text(label!, style: const TextStyle(fontSize: 14))),
      ClipRRect(borderRadius: BorderRadius.circular(30), child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14), child: TextField(
        controller: controller,
        focusNode: focusNode,
        keyboardType: keyboardType,
        obscureText: obscure,
        maxLength: maxLength,
        autofillHints: noAutofill ? const <String>[] : autofillHints,
        enableSuggestions: !noAutofill,
        autocorrect: !noAutofill,
        style: const TextStyle(fontSize: 16),
        decoration: InputDecoration(
          hintText: hint,
          counterText: '',
          filled: true,
          fillColor: (Theme.of(context).brightness == Brightness.dark ? Colors.white.withValues(alpha: 0.08) : Colors.white.withValues(alpha: 0.5)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          border: border,
          enabledBorder: border,
          focusedBorder: border.copyWith(borderSide: BorderSide(color: Brand.indigoHi, width: 3)),
        ),
      ))),
    ]);
  }
}

class PagerDots extends StatelessWidget {
  const PagerDots({super.key, required this.index});
  final int index;
  @override
  Widget build(BuildContext context) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < 3; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.symmetric(horizontal: 7),
              width: i == index ? 30 : 13,
              height: 13,
              decoration: BoxDecoration(color: i == index ? Brand.indigo : Brand.lavender.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(99)),
            ),
        ],
      );
}
