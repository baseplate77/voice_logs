import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

/// App-wide visual system: dark canvas, bright orchid primary, and muted
/// lavender accent. Keep these constants centralized so feature UI stays
/// visually consistent instead of drifting into one-off colors.
class VoxAppColors {
  const VoxAppColors._();

  static const Color primary = Color(0xFF1D1D1F); // Solid charcoal black
  static const Color accent = Color(0xFFE13C30); // Classic retro red
  static const Color canvas = Color(
    0xFFF4F4F4,
  ); // Warm light-grey/off-white backdrop
  static const Color surface = Color(0xFFFFFFFF); // Pure white cards/containers
  static const Color surfaceHigh = Color(0xFFEBEBEB);
  static const Color ink = Color(0xFF1D1D1F);
  static const Color muted = Color(0xFF7A7A7A);
  static const Color soft = Color(0xFFFAFAFA);
  static const Color softAccent = Color(0xFFF5EBEB);
  static const Color outline = Color(0xFFE2E2E2);
  static const Color error = Color(0xFFD32F2F);
}

ThemeData buildVoxTheme() {
  const scheme = ColorScheme.light(
    primary: VoxAppColors.primary,
    primaryContainer: Color(0xFFF5EBEB),
    onPrimaryContainer: VoxAppColors.primary,
    secondary: VoxAppColors.accent,
    onSecondary: Colors.white,
    secondaryContainer: VoxAppColors.softAccent,
    onSecondaryContainer: VoxAppColors.ink,
    tertiary: VoxAppColors.accent,
    onTertiary: Colors.white,
    tertiaryContainer: Color(0xFFF5EBEB),
    onTertiaryContainer: VoxAppColors.ink,
    error: VoxAppColors.error,
    onSurface: VoxAppColors.ink,
    surfaceContainerLowest: Color(0xFFFFFFFF),
    surfaceContainerLow: Color(0xFFFAFAFA),
    surfaceContainer: VoxAppColors.surface,
    surfaceContainerHigh: VoxAppColors.surfaceHigh,
    surfaceContainerHighest: Color(0xFFEBEBEB),
    onSurfaceVariant: VoxAppColors.muted,
    outline: VoxAppColors.outline,
    outlineVariant: Color(0xFFE2E2E2),
    shadow: Color(0x0F000000),
    scrim: Color(0x55000000),
  );

  final base = ThemeData(useMaterial3: true, colorScheme: scheme);
  final textTheme = base.textTheme.apply(
    bodyColor: VoxAppColors.ink,
    displayColor: VoxAppColors.ink,
  );

  const retroMonospace = TextStyle(fontFamily: 'monospace');

  return base.copyWith(
    scaffoldBackgroundColor: VoxAppColors.canvas,
    canvasColor: VoxAppColors.canvas,
    textTheme: textTheme.copyWith(
      displayLarge: textTheme.displayLarge?.merge(retroMonospace),
      displayMedium: textTheme.displayMedium?.merge(retroMonospace),
      displaySmall: textTheme.displaySmall?.merge(retroMonospace),
      headlineLarge: textTheme.headlineLarge?.merge(retroMonospace),
      headlineMedium: textTheme.headlineMedium?.merge(retroMonospace),
      headlineSmall: textTheme.headlineSmall?.merge(retroMonospace),
      titleLarge: textTheme.titleLarge?.merge(retroMonospace),
      titleMedium: textTheme.titleMedium?.merge(retroMonospace),
      titleSmall: textTheme.titleSmall?.merge(retroMonospace),
    ),
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
        fontFamily: 'monospace',
      ),
    ),
    iconTheme: const IconThemeData(color: VoxAppColors.ink),
    dividerTheme: DividerThemeData(
      color: VoxAppColors.outline,
      thickness: 1.r,
      space: 1.r,
    ),
    cardTheme: CardThemeData(
      elevation: 2,
      color: VoxAppColors.surface,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.black.withValues(alpha: 0.05),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16.r),
        side: const BorderSide(color: VoxAppColors.outline),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: VoxAppColors.surface,
      selectedColor: VoxAppColors.primary,
      secondarySelectedColor: VoxAppColors.accent,
      labelStyle: textTheme.labelLarge?.copyWith(color: VoxAppColors.ink),
      secondaryLabelStyle: textTheme.labelLarge?.copyWith(color: Colors.white),
      side: const BorderSide(color: VoxAppColors.outline),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.r)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: VoxAppColors.surface,
      hintStyle: TextStyle(color: VoxAppColors.muted.withValues(alpha: 0.82)),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12.r),
        borderSide: const BorderSide(color: VoxAppColors.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12.r),
        borderSide: const BorderSide(color: VoxAppColors.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12.r),
        borderSide: BorderSide(color: VoxAppColors.primary, width: 1.4.r),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: VoxAppColors.primary,
        foregroundColor: Colors.white,
        disabledBackgroundColor: VoxAppColors.surfaceHigh,
        disabledForegroundColor: VoxAppColors.muted,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12.r),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: VoxAppColors.primary,
        side: const BorderSide(color: VoxAppColors.outline),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12.r),
        ),
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
            ? VoxAppColors.accent
            : VoxAppColors.muted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? VoxAppColors.accent.withValues(alpha: 0.28)
            : VoxAppColors.surfaceHigh,
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: VoxAppColors.accent,
      circularTrackColor: VoxAppColors.surfaceHigh,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: VoxAppColors.surface,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: VoxAppColors.surface,
      showDragHandle: true,
      dragHandleColor: VoxAppColors.muted,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: VoxAppColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16.r)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: VoxAppColors.primary,
      contentTextStyle: textTheme.bodyMedium?.copyWith(color: Colors.white),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.r)),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: VoxAppColors.accent,
      textColor: VoxAppColors.ink,
      subtitleTextStyle: textTheme.bodySmall?.copyWith(
        color: VoxAppColors.muted,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.r)),
    ),
  );
}
