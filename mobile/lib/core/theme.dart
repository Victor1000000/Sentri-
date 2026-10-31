import 'package:flutter/material.dart';

/// Sentri's look. One calm base, one alarm colour used only for SOS, one reassurance colour.
/// Both themes share the same roles so screens never hard-code colours.
class SentriColors {
  static const alarm = Color(0xFFC8201A);
  static const alarmDark = Color(0xFFE0443D);
  static const safe = Color(0xFF1F7A4D);
  static const safeDark = Color(0xFF4CC388);
}

/// Light / dark / follow the phone. The language sheet changes it, and the choice is saved with the settings.
class ThemeChoice {
  static final mode = ValueNotifier<ThemeMode>(ThemeMode.system);
  static Future<void> Function(String name)? persist;

  static ThemeMode parse(String? s) => switch (s) { 'light' => ThemeMode.light, 'dark' => ThemeMode.dark, _ => ThemeMode.system };

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
    surface: dark ? const Color(0xFF0D0C2E) : const Color(0xFFEDEDFF),
    error: dark ? SentriColors.alarmDark : SentriColors.alarm,
    tertiary: dark ? SentriColors.safeDark : SentriColors.safe,
  );
  final text = (dark ? ThemeData.dark() : ThemeData.light()).textTheme.apply(
        bodyColor: base.onSurface,
        displayColor: base.onSurface,
      );
  return ThemeData(
    useMaterial3: true,
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
      elevation: 0,
      margin: EdgeInsets.zero,
      color: dark ? const Color(0xFF18174D) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: base.outlineVariant),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFF0E08A3),
        // The scheme picks a dark label when the app is dark, which disappeared on this dark
        // button. White always reads on it, light and dark alike.
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xFF1A1948) : Colors.white,
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
