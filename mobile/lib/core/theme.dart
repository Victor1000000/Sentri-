import 'package:flutter/material.dart';

/// The app-wide background wash, used by [SentriBackground] and the page backdrop.
///
/// Two radial colour pools: warm indigo at the top right, mint at the bottom left,
/// plus a whisper of amber between them - complementary to both. Dark mode lets
/// them breathe (11%) - that is the cool blend behind every dark screen. Light
/// mode wears the same three hues, softened to sit on white (10% indigo/mint,
/// 7% amber) so the day theme carries the same colour life without ever
/// lowering text contrast.
class WashPainter extends CustomPainter {
  const WashPainter({required this.dark});
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final pools = dark
        ? const [
            (color: Color(0xFF6A5FF0), alpha: 0.11),
            (color: Color(0xFF17B86A), alpha: 0.11),
            (color: Color(0xFFE5A33C), alpha: 0.07),
          ]
        : const [
            (color: Color(0xFF6A5FF0), alpha: 0.10),
            (color: Color(0xFF17B86A), alpha: 0.10),
            (color: Color(0xFFE5A33C), alpha: 0.07),
          ];
    final centres = [
      Offset(size.width * 1.02, -size.width * 0.18),
      Offset(-size.width * 0.18, size.height * 1.05),
      Offset(size.width * 0.85, size.height * 0.92),
    ];
    final radii = [size.width * 0.85, size.width * 0.9, size.width * 0.55];
    for (var i = 0; i < pools.length; i++) {
      final p = pools[i];
      canvas.drawCircle(
        centres[i],
        radii[i],
        Paint()
          ..shader = RadialGradient(
            colors: [p.color.withValues(alpha: p.alpha), p.color.withValues(alpha: 0.0)],
          ).createShader(Rect.fromCircle(center: centres[i], radius: radii[i])),
      );
    }
  }

  @override
  bool shouldRepaint(WashPainter oldDelegate) => oldDelegate.dark != dark;
}

/// Sentri's look. One calm base, one alarm colour used only for SOS, one reassurance colour.
/// Both themes share the same roles so screens never hard-code colours.
class SentriColors {
  static const alarm = Color(0xFFC8201A);
  static const alarmDark = Color(0xFFE0443D);
  static const safe = Color(0xFF1F7A4D);
  static const safeDark = Color(0xFF4CC388);

  // The warm, humane layer (the parts of the app about the person's own day:
  // Home's greeting, the Health tab, exercise). Near-black panels at night,
  // white panels in the day, and one lime energy note - the colour of fresh
  // leaves and morning runs, reading well with photos of real people.
  static const surfaceDark = Color(0xFF0E0F12);
  static const cardDark = Color(0xFF17181D);
  static const surfaceLight = Color(0xFFF4F3F9);
  static const inkDark = Color(0xFF17181C); // the dark "ink" chip/button in light mode
  static const lime = Color(0xFFC6F16E); // lime accentic on dark panels
  static const limeDeep = Color(0xFF8FB836); // lime that still reads on white
}

/// Light / dark / follow the phone. The language sheet changes it, and the choice is saved with the settings.
/// Light is the default: safety apps should read clearly in daylight, and a tap on the mode button
/// still flips to dark for night use.
class ThemeChoice {
  static final mode = ValueNotifier<ThemeMode>(ThemeMode.light);
  static Future<void> Function(String name)? persist;

  // 'system' was the old default; it now counts as unset so light is the default for everyone.
  static ThemeMode parse(String? s) => switch (s) { 'dark' => ThemeMode.dark, _ => ThemeMode.light };

  static Future<void> set(ThemeMode m) async {
    mode.value = m;
    await persist?.call(m.name);
  }
}

ThemeData sentriTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final base = ColorScheme.fromSeed(
    seedColor: const Color(0xFF0E08A3),
    brightness: b,
  ).copyWith(
    surface: dark ? SentriColors.surfaceDark : SentriColors.surfaceLight,
    error: dark ? SentriColors.alarmDark : SentriColors.alarm,
    tertiary: dark ? SentriColors.safeDark : SentriColors.safe,
  );
  // Inter everywhere: the calm, grid-like letterforms Google Maps and Uber use, so every screen
  // reads as one family. The face is bundled inside the app (see core/fonts.dart), so the very
  // first launch - even offline - already paints with the brand font. Nothing is fetched from
  // the network any more, so no more serif fallback on first open.
  final text = (dark ? ThemeData.dark() : ThemeData.light()).textTheme.apply(
        fontFamily: 'Inter',
        bodyColor: base.onSurface,
        displayColor: base.onSurface,
      );
  // The action colour: the near-black "ink" pill in the day, the lime energy pill at
  // night - both straight from the reference look, always readable with its text.
  final actionColor = dark ? SentriColors.lime : SentriColors.inkDark;
  final onAction = dark ? Colors.black.withValues(alpha: 0.85) : Colors.white;
  return ThemeData(
    useMaterial3: true,
    // No ink splashes: the Android 12 sparkle ripple read as a glitch on these buttons.
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    colorScheme: base,
    scaffoldBackgroundColor: base.surface,
    textTheme: text.copyWith(
      headlineMedium: text.headlineMedium?.copyWith(fontWeight: FontWeight.w500, letterSpacing: -1, height: 1.1),
      headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w600, fontSize: 25, letterSpacing: -0.6, height: 1.15),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600, fontSize: 16),
      bodyLarge: text.bodyLarge?.copyWith(fontSize: 15, height: 1.4),
      bodyMedium: text.bodyMedium?.copyWith(fontSize: 14, height: 1.4),
      bodySmall: text.bodySmall?.copyWith(fontSize: 12.5, height: 1.35),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: base.surface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge?.copyWith(fontWeight: FontWeight.w800, letterSpacing: 0.3, color: base.onSurface),
    ),
    cardTheme: CardThemeData(
      elevation: dark ? 0 : 1,
      margin: EdgeInsets.zero,
      color: dark ? SentriColors.cardDark : Colors.white,
      shadowColor: Colors.black.withValues(alpha: 0.05),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: base.outlineVariant.withValues(alpha: dark ? 0.0 : 1)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: actionColor,
        // Labels always match their own panel: white on the day-ink, near-black on the
        // night-lime, so the buttons read in both modes without per-screen fixes.
        foregroundColor: onAction,
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        side: BorderSide(color: base.outlineVariant),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? SentriColors.cardDark : Colors.white,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: BorderSide(color: base.outlineVariant)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: BorderSide(color: base.outlineVariant)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? base.onPrimary : base.outline),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? base.primary : base.surfaceContainerHighest),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}
