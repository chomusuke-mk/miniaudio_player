import 'package:flutter/material.dart';

/// Design tokens and chromatic palette matching `pictures/miniaudio_player.svg`.
abstract final class StudioColors {
  // Background gradient stops
  static const Color bgGradientStart = Color(0xFF070B14);
  static const Color bgGradientMid = Color(0xFF0C1222);
  static const Color bgGradientEnd = Color(0xFF060911);
  static const Color backgroundDark = bgGradientStart;

  // Radial neon glow accents
  static const Color glowCyan = Color(0x2E0284C7);
  static const Color glowViolet = Color(0x247C3AED);
  static const Color glowEmerald = Color(0x1A059669);

  // Card surfaces and borders
  static const Color cardBackground = Color(0xD9111C35);
  static const Color cardBackgroundDark = Color(0xF20A101F);
  static const Color cardBorder = Color(0xFF1E293B);
  static const Color cardBorderFocused = Color(0xFF334155);

  // Neon accents
  static const Color accentCyan = Color(0xFF38BDF8);
  static const Color accentBlue = Color(0xFF2563EB);
  static const Color accentViolet = Color(0xFF818CF8);
  static const Color accentPurple = Color(0xFFC084FC);
  static const Color accentEmerald = Color(0xFF10B981);
  static const Color accentAmber = Color(0xFFF59E0B);
  static const Color accentGold = Color(0xFFFBBF24);
  static const Color accentRose = Color(0xFFF43F5E);

  // Typography hierarchy
  static const Color textPrimary = Color(0xFFF8FAFC);
  static const Color textSecondary = Color(0xFF94A3B8);
  static const Color textMuted = Color(0xFF64748B);

  // Surface gradients
  static const LinearGradient titleGradient = LinearGradient(
    colors: [accentCyan, accentViolet, accentPurple],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );

  static const LinearGradient cardGradient = LinearGradient(
    colors: [cardBackground, cardBackgroundDark],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  static const LinearGradient cyanBlueGradient = LinearGradient(
    colors: [accentCyan, accentBlue],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

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
