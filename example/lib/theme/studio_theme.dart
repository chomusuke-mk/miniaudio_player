import 'package:flutter/material.dart';
import 'studio_colors.dart';

abstract final class StudioTheme {
  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: StudioColors.bgGradientStart,
      colorScheme: const ColorScheme.dark(
        primary: StudioColors.accentCyan,
        secondary: StudioColors.accentViolet,
        tertiary: StudioColors.accentEmerald,
        surface: StudioColors.cardBackgroundDark,
        surfaceContainerHighest: StudioColors.cardBackground,
        onPrimary: Colors.black,
        onSecondary: Colors.white,
        onSurface: StudioColors.textPrimary,
        error: StudioColors.accentRose,
      ),
      cardTheme: CardThemeData(
        color: StudioColors.cardBackgroundDark,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(
            color: StudioColors.cardBorder,
            width: 1.2,
          ),
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: StudioColors.accentCyan,
        inactiveTrackColor: StudioColors.cardBorderFocused,
        thumbColor: StudioColors.accentCyan,
        overlayColor: StudioColors.accentCyan.withValues(alpha: 0.15),
        trackHeight: 3.0,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.0),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return StudioColors.accentCyan;
          }
          return StudioColors.textMuted;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return StudioColors.accentCyan.withValues(alpha: 0.35);
          }
          return StudioColors.cardBorder;
        }),
        trackOutlineColor: WidgetStateProperty.all(StudioColors.cardBorder),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: StudioColors.cardBackgroundDark,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: StudioColors.cardBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: StudioColors.cardBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(
            color: StudioColors.accentCyan,
            width: 1.5,
          ),
        ),
        labelStyle: const TextStyle(
          color: StudioColors.textSecondary,
          fontSize: 12,
        ),
      ),
      fontFamily: 'Roboto',
      useMaterial3: true,
    );
  }
}
