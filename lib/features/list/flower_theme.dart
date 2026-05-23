import 'package:flutter/material.dart';
import 'package:iconsax/iconsax.dart';

/// Visual mapping for the `flowerType` mood classifier produced by the
/// refine response parser. Each flower carries an emotional connotation
/// (see `_validFlowerTypes` in lib/features/refine/response_parser.dart)
/// — surfacing it as a color stripe lets the user scan the home list by
/// vibe without reading titles.
class FlowerTheme {
  const FlowerTheme({required this.color, required this.icon});

  final Color color;
  final IconData icon;

  static const _palette = <String, FlowerTheme>{
    'sakura': FlowerTheme(color: Color(0xFFE7A6B8), icon: Iconsax.heart),
    'lavender': FlowerTheme(color: Color(0xFFB5A8D6), icon: Iconsax.moon),
    'cactus': FlowerTheme(color: Color(0xFF8AA889), icon: Iconsax.cloud),
    'sunflower': FlowerTheme(color: Color(0xFFE6BE5C), icon: Iconsax.sun_1),
    'fern': FlowerTheme(color: Color(0xFF7BAE8B), icon: Iconsax.tree),
    'mushroom': FlowerTheme(color: Color(0xFFB89A78), icon: Iconsax.lamp),
    'rose': FlowerTheme(color: Color(0xFFD86E6E), icon: Iconsax.heart_circle),
  };

  static const _fallback = FlowerTheme(
    color: Color(0xFFC8C8C8),
    icon: Iconsax.note,
  );

  static FlowerTheme forFlower(String? flowerType) {
    if (flowerType == null) return _fallback;
    return _palette[flowerType.toLowerCase()] ?? _fallback;
  }
}
