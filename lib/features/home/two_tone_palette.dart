import 'package:flutter/material.dart';

import '../../app_theme.dart';

/// Home/recording palette mapped onto the app-wide white + orchid/lavender
/// visual system. Kept as a small facade so older home widgets stay simple.
class TwoTonePalette {
  const TwoTonePalette._();

  /// White content canvas.
  static const Color canvas = VoxAppColors.canvas;

  /// Saturated action surface.
  static const Color slab = VoxAppColors.primary;

  /// Soft lavender highlight on the canvas zone.
  static const Color slabOnLight = VoxAppColors.softAccent;

  /// Body text on the canvas zone.
  static const Color fgPrimary = VoxAppColors.ink;

  /// Text and icons that sit on the saturated action surface.
  static const Color fgOnSlab = Colors.white;

  /// Muted secondary text.
  static const Color fgMuted = VoxAppColors.muted;

  /// Primary action accent — recording, playhead, active states.
  static const Color accentRed = VoxAppColors.primary;

  /// Soft accent wash used for pressed/active states.
  static const Color accentRedSoft = VoxAppColors.softAccent;
}

/// Editorial label style — uppercase, wide tracking. Used for ALL-CAPS
/// section labels on both light and dark zones.
TextStyle labelCaps(Color color) => TextStyle(
  fontSize: 12,
  fontWeight: FontWeight.w600,
  letterSpacing: 1.6,
  color: color,
);
