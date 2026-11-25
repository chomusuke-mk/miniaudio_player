import 'package:material_ui/material_ui.dart';

/// Design tokens and chromatic palette matching `pictures/miniaudio_player.svg`.
abstract final class StudioColors {
  /// Primary dark gradient start color.
  static const Color bgGradientStart = Color(0xFF070B14);

  /// Middle dark gradient stop color.
  static const Color bgGradientMid = Color(0xFF0C1222);

  /// Terminal dark gradient stop color.
  static const Color bgGradientEnd = Color(0xFF060911);

  /// Default dark canvas background color.
  static const Color backgroundDark = bgGradientStart;

  /// Translucent cyan radial ambient glow.
  static const Color glowCyan = Color(0x2E0284C7);

  /// Translucent violet radial ambient glow.
  static const Color glowViolet = Color(0x247C3AED);

  /// Translucent emerald radial ambient glow.
  static const Color glowEmerald = Color(0x1A059669);

  /// Top card surface color.
  static const Color cardBackground = Color(0xD9111C35);

  /// Bottom dark card surface color.
  static const Color cardBackgroundDark = Color(0xF20A101F);

  /// Subtle card outline border color.
  static const Color cardBorder = Color(0xFF1E293B);

  /// Highlighted card outline border color.
  static const Color cardBorderFocused = Color(0xFF334155);

  /// Neon cyan accent color for primary highlights.
  static const Color accentCyan = Color(0xFF38BDF8);

  /// Neon cobalt blue accent color.
  static const Color accentBlue = Color(0xFF2563EB);

  /// Neon violet accent color.
  static const Color accentViolet = Color(0xFF818CF8);

  /// Neon purple accent color.
  static const Color accentPurple = Color(0xFFC084FC);

  /// Neon emerald accent color for healthy/active indicators.
  static const Color accentEmerald = Color(0xFF10B981);

  /// Neon amber accent color for warnings or telemetry badges.
  static const Color accentAmber = Color(0xFFF59E0B);

  /// Warm gold accent color.
  static const Color accentGold = Color(0xFFFBBF24);

  /// Neon rose accent color for recording, clipping, or error states.
  static const Color accentRose = Color(0xFFF43F5E);

  /// Primary high-contrast foreground text color.
  static const Color textPrimary = Color(0xFFF8FAFC);

  /// Secondary foreground text color for subtitles and captions.
  static const Color textSecondary = Color(0xFF94A3B8);

  /// Muted foreground text color for inactive elements and placeholders.
  static const Color textMuted = Color(0xFF64748B);

  /// Linear title gradient spanning cyan, violet, and purple accents.
  static const LinearGradient titleGradient = LinearGradient(
    colors: [accentCyan, accentViolet, accentPurple],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );

  /// Vertical gradient background used by studio cards.
  static const LinearGradient cardGradient = LinearGradient(
    colors: [cardBackground, cardBackgroundDark],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  /// Diagonal cyan-to-blue gradient for primary controls.
  static const LinearGradient cyanBlueGradient = LinearGradient(
    colors: [accentCyan, accentBlue],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// Vertical frequency spectrum gradient from cyan to rose peak.
  static const LinearGradient spectrumGradient = LinearGradient(
    colors: [
      Color(0xFF06B6D4),
      Color(0xFF3B82F6),
      Color(0xFF8B5CF6),
      Color(0xFFF43F5E),
    ],
    begin: Alignment.bottomCenter,
    end: Alignment.topCenter,
  );
}
