import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../theme/studio_colors.dart';

class SpectrumPainter extends CustomPainter {
  final ValueListenable<VisualizerData> dataListenable;
  final bool isActive;

  static const List<String> frequencyLabels = [
    '31',
    '63',
    '125',
    '250',
    '500',
    '1k',
    '2k',
    '4k',
    '8k',
    '16k',
  ];

  static const List<(String, double)> _dbLevels = [
    ('0 dB', 0.15),
    ('-12 dB', 0.40),
    ('-24 dB', 0.65),
    ('-36 dB', 0.90),
  ];

  static final Paint _bgPaint = Paint()..color = const Color(0xFF0A0F1D);
  static final Paint _gridPaint = Paint()
    ..color = StudioColors.cardBorder.withValues(alpha: 0.6)
    ..strokeWidth = 1.0;
  static final Paint _capPaint = Paint()
    ..color = Colors.white.withValues(alpha: 0.9)
    ..strokeWidth = 1.5;
  static final Paint _barPaint = Paint()..style = PaintingStyle.fill;

  static TextPainter _layoutLabel(String text, TextStyle style) {
    return TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  static final List<TextPainter> _dbLabelPainters = [
    for (final level in _dbLevels)
      _layoutLabel(
        level.$1,
        const TextStyle(
          color: StudioColors.textMuted,
          fontSize: 8.0,
          fontWeight: FontWeight.w600,
        ),
      ),
  ];

  static final List<TextPainter> _activeFreqPainters = [
    for (final label in frequencyLabels)
      _layoutLabel(
        label,
        const TextStyle(
          color: StudioColors.textSecondary,
          fontSize: 8.0,
          fontWeight: FontWeight.w700,
        ),
      ),
  ];

  static final List<TextPainter> _inactiveFreqPainters = [
    for (final label in frequencyLabels)
      _layoutLabel(
        label,
        const TextStyle(
          color: StudioColors.textMuted,
          fontSize: 8.0,
          fontWeight: FontWeight.w700,
        ),
      ),
  ];

  SpectrumPainter({required this.dataListenable, this.isActive = true})
    : super(repaint: dataListenable);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)),
      _bgPaint,
    );

    // Draw horizontal grid lines for 0dB, -12dB, -24dB, -36dB
    for (int i = 0; i < _dbLevels.length; i++) {
      final y = size.height * _dbLevels[i].$2;
      canvas.drawLine(Offset(28, y), Offset(size.width - 6, y), _gridPaint);
      _dbLabelPainters[i].paint(canvas, Offset(2, y - 5));
    }

    final barAreaWidth = size.width - 34;
    const bandCount = 10;
    final totalBarSpacing = barAreaWidth * 0.25;
    final barSpacing = totalBarSpacing / (bandCount + 1);
    final barWidth = (barAreaWidth - totalBarSpacing) / bandCount;

    final magnitudes = dataListenable.value.bands;
    final barGradient = StudioColors.spectrumGradient;
    final freqPainters = isActive ? _activeFreqPainters : _inactiveFreqPainters;

    for (int i = 0; i < bandCount; i++) {
      final mag = (i < magnitudes.length && isActive)
          ? magnitudes[i].clamp(0.0, 1.0)
          : 0.05;

      final x = 32 + (i * (barWidth + barSpacing)) + barSpacing;
      final barHeight = max(4.0, (size.height - 24) * mag);
      final y = size.height - 18 - barHeight;

      final rect = Rect.fromLTWH(x, y, barWidth, barHeight);
      _barPaint.shader = barGradient.createShader(rect);

      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(3)),
        _barPaint,
      );

      // Peak cap line
      if (isActive && mag > 0.1) {
        canvas.drawLine(
          Offset(x, y - 2),
          Offset(x + barWidth, y - 2),
          _capPaint,
        );
      }

      // Frequency label at bottom (pre-laid out)
      final labelPainter = freqPainters[i];
      final labelX = x + (barWidth - labelPainter.width) / 2;
      labelPainter.paint(canvas, Offset(labelX, size.height - 13));
    }
  }

  @override
  bool shouldRepaint(covariant SpectrumPainter oldDelegate) {
    return oldDelegate.isActive != isActive ||
        oldDelegate.dataListenable != dataListenable;
  }
}
