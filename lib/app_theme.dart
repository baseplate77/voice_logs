import 'package:flutter/material.dart';

/// App-wide visual system: white canvas, bright orchid primary, and soft
/// lavender accent. Keep these constants centralized so feature UI stays
/// visually consistent instead of drifting into one-off colors.
class VoxAppColors {
  const VoxAppColors._();

  static const Color primary = Color(0xFFD552A3);
  static const Color accent = Color(0xFFBDA6CE);
  static const Color canvas = Color(0xFFFFFFFF);
  static const Color ink = Color(0xFF211727);
  static const Color muted = Color(0xFF7D6B86);
  static const Color soft = Color(0xFFF8F2FA);
  static const Color softAccent = Color(0xFFF0E7F5);
  static const Color outline = Color(0xFFE8DDED);
  static const Color error = Color(0xFFB3266B);
}

ThemeData buildVoxTheme() {
  const scheme = ColorScheme.light(
    primary: VoxAppColors.primary,
    primaryContainer: Color(0xFFF9D8EB),
    onPrimaryContainer: Color(0xFF3A1230),
    secondary: VoxAppColors.accent,
    onSecondary: VoxAppColors.ink,
    secondaryContainer: VoxAppColors.softAccent,
    onSecondaryContainer: VoxAppColors.ink,
    tertiary: VoxAppColors.accent,
    onTertiary: VoxAppColors.ink,
    tertiaryContainer: Color(0xFFEEDFF7),
    onTertiaryContainer: Color(0xFF2B153A),
    error: VoxAppColors.error,
    onSurface: VoxAppColors.ink,
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: Color(0xFFFEF9FF),
    surfaceContainer: VoxAppColors.soft,
    surfaceContainerHigh: Color(0xFFF3EAF7),
    surfaceContainerHighest: VoxAppColors.softAccent,
    onSurfaceVariant: VoxAppColors.muted,
    outline: VoxAppColors.outline,
    outlineVariant: VoxAppColors.outline,
    shadow: Color(0x22000000),
    scrim: Color(0x66000000),
  );

  final base = ThemeData(useMaterial3: true, colorScheme: scheme);
  final textTheme = base.textTheme.apply(
    bodyColor: VoxAppColors.ink,
    displayColor: VoxAppColors.ink,
  );

  return base.copyWith(
    scaffoldBackgroundColor: VoxAppColors.canvas,
    canvasColor: VoxAppColors.canvas,
    textTheme: textTheme,
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      backgroundColor: VoxAppColors.canvas,
      foregroundColor: VoxAppColors.ink,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: textTheme.titleLarge?.copyWith(
        color: VoxAppColors.ink,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
      ),
    ),
    iconTheme: const IconThemeData(color: VoxAppColors.ink),
    dividerTheme: const DividerThemeData(
      color: VoxAppColors.outline,
      thickness: 1,
      space: 1,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: VoxAppColors.canvas,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: const BorderSide(color: VoxAppColors.outline),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: VoxAppColors.canvas,
      selectedColor: VoxAppColors.primary,
      secondarySelectedColor: VoxAppColors.accent,
      labelStyle: textTheme.labelLarge?.copyWith(color: VoxAppColors.ink),
      secondaryLabelStyle: textTheme.labelLarge?.copyWith(color: Colors.white),
      side: const BorderSide(color: VoxAppColors.outline),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: VoxAppColors.soft,
      hintStyle: TextStyle(color: VoxAppColors.muted.withValues(alpha: 0.82)),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(22),
        borderSide: const BorderSide(color: VoxAppColors.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(22),
        borderSide: const BorderSide(color: VoxAppColors.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(22),
        borderSide: const BorderSide(color: VoxAppColors.primary, width: 1.4),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: VoxAppColors.primary,
        foregroundColor: Colors.white,
        disabledBackgroundColor: VoxAppColors.softAccent,
        disabledForegroundColor: VoxAppColors.muted,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: VoxAppColors.primary,
        side: const BorderSide(color: VoxAppColors.outline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: VoxAppColors.primary),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: VoxAppColors.primary,
      foregroundColor: Colors.white,
      shape: StadiumBorder(),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? VoxAppColors.primary
            : VoxAppColors.muted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? VoxAppColors.primary.withValues(alpha: 0.28)
            : VoxAppColors.softAccent,
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: VoxAppColors.primary,
      circularTrackColor: VoxAppColors.softAccent,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: VoxAppColors.canvas,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: VoxAppColors.canvas,
      showDragHandle: true,
      dragHandleColor: VoxAppColors.accent,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: VoxAppColors.canvas,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: VoxAppColors.ink,
      contentTextStyle: textTheme.bodyMedium?.copyWith(color: Colors.white),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: VoxAppColors.primary,
      textColor: VoxAppColors.ink,
      subtitleTextStyle: textTheme.bodySmall?.copyWith(
        color: VoxAppColors.muted,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
  );
}
