import 'package:flutter/material.dart';

/// Design tokens shared with the Windows HUD (app/styles.css): same colours, orb palette,
/// radii and hairlines, so Snapy looks like one product on every device.
class SnapyColors {
  final Color bg, surface, card, hair, hairStrong, text, text2, text3, fill, accent, accentSoft, green, red, orange;
  const SnapyColors({
    required this.bg, required this.surface, required this.card, required this.hair, required this.hairStrong,
    required this.text, required this.text2, required this.text3, required this.fill, required this.accent,
    required this.accentSoft, required this.green, required this.red, required this.orange,
  });

  static const light = SnapyColors(
    bg: Color(0xFFF5F5F7), surface: Color(0xE0FAFAFC), card: Color(0xFFFFFFFF), hair: Color(0x17000000),
    hairStrong: Color(0x29000000), text: Color(0xFF1D1D1F), text2: Color(0xFF6E6E73), text3: Color(0xFFA1A1A6),
    fill: Color(0x1F767680), accent: Color(0xFF0A84FF), accentSoft: Color(0x1F0A84FF),
    green: Color(0xFF30D158), red: Color(0xFFFF3B30), orange: Color(0xFFFF9F0A),
  );
  static const dark = SnapyColors(
    bg: Color(0xFF000000), surface: Color(0xDB1E1E20), card: Color(0xFF1C1C1E), hair: Color(0x1AFFFFFF),
    hairStrong: Color(0x2EFFFFFF), text: Color(0xFFF5F5F7), text2: Color(0xFFA1A1A6), text3: Color(0xFF6E6E73),
    fill: Color(0x3D767680), accent: Color(0xFF0A84FF), accentSoft: Color(0x380A84FF),
    green: Color(0xFF30D158), red: Color(0xFFFF453A), orange: Color(0xFFFF9F0A),
  );

  static SnapyColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

/// The orb's idle palette (app/orb.js PALETTES.idle).
const orbPalette = [Color(0xFF5E81FF), Color(0xFF966EFF), Color(0xFF46C8FF)];

const double rLg = 16, r = 12, rSm = 8;

ThemeData snapyTheme(Brightness b) {
  final c = b == Brightness.dark ? SnapyColors.dark : SnapyColors.light;
  return ThemeData(
    useMaterial3: true,
    brightness: b,
    scaffoldBackgroundColor: c.bg,
    colorScheme: ColorScheme.fromSeed(seedColor: c.accent, brightness: b, surface: c.card),
    fontFamily: null, // system font (Roboto / OEM font) — matches the HUD's "system UI" approach
    textTheme: TextTheme(
      headlineMedium: TextStyle(fontSize: 28, fontWeight: FontWeight.w600, letterSpacing: -0.6, color: c.text),
      titleMedium: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: -0.2, color: c.text),
      bodyMedium: TextStyle(fontSize: 15, height: 1.4, color: c.text),
      bodySmall: TextStyle(fontSize: 13, height: 1.4, color: c.text2),
    ),
    dividerColor: c.hair,
  );
}
