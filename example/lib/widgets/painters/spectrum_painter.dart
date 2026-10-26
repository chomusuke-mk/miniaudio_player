import 'dart:math';
import 'package:flutter/material.dart';
import '../../theme/studio_colors.dart';

class SpectrumPainter extends CustomPainter {
  final List<double> magnitudes;
  final bool isActive;

  static const List<String> frequencyLabels = [
    '31', '63', '125', '250', '500', '1k', '2k', '4k', '8k', '16k'
  ];

  const SpectrumPainter({
    required this.magnitudes,
    this.isActive = true,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final bgPaint = Paint()..color = const Color(0xFF0A0F1D);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)),
      bgPaint,
    );

    // Draw horizontal grid lines for 0dB, -12dB, -24dB, -36dB
    final gridPaint = Paint()
      ..color = StudioColors.cardBorder.withValues(alpha: 0.6)
      ..strokeWidth = 1.0;

    final textPainter = TextPainter(textDirection: TextDirection.ltr);

    const dbLevels = [
      ('0 dB', 0.15),
      ('-12 dB', 0.40),
      ('-24 dB', 0.65),
      ('-36 dB', 0.90),
    ];

    for (final level in dbLevels) {
      final y = size.height * level.$2;
      canvas.drawLine(Offset(28, y), Offset(size.width - 6, y), gridPaint);

      textPainter.text = TextSpan(
        text: level.$1,
        style: const TextStyle(
          color: StudioColors.textMuted,
          fontSize: 8.0,
          fontWeight: FontWeight.w600,
        ),
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(2, y - 5));
    }

    final barAreaWidth = size.width - 34;
    const bandCount = 10;
    final totalBarSpacing = barAreaWidth * 0.25;
    final barSpacing = totalBarSpacing / (bandCount + 1);
    final barWidth = (barAreaWidth - totalBarSpacing) / bandCount;

    final barGradient = StudioColors.spectrumGradient;

    for (int i = 0; i < bandCount; i++) {
      final mag = (i < magnitudes.length && isActive)
          ? magnitudes[i].clamp(0.0, 1.0)
          : 0.05;

      final x = 32 + (i * (barWidth + barSpacing)) + barSpacing;
      final barHeight = max(4.0, (size.height - 24) * mag);
      final y = size.height - 18 - barHeight;

      final rect = Rect.fromLTWH(x, y, barWidth, barHeight);
      final barPaint = Paint()
        ..shader = barGradient.createShader(rect)
        ..style = PaintingStyle.fill;

      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(3)),
        barPaint,
      );

      // Peak cap line
      if (isActive && mag > 0.1) {
        final capPaint = Paint()
          ..color = Colors.white.withValues(alpha: 0.9)
          ..strokeWidth = 1.5;
        canvas.drawLine(
          Offset(x, y - 2),
          Offset(x + barWidth, y - 2),
          capPaint,
        );
      }

      // Frequency label at bottom
      textPainter.text = TextSpan(
        text: frequencyLabels[i],
        style: TextStyle(
          color: isActive ? StudioColors.textSecondary : StudioColors.textMuted,
          fontSize: 8.0,
          fontWeight: FontWeight.w700,
        ),
      );
      textPainter.layout();
      final labelX = x + (barWidth - textPainter.width) / 2;
      textPainter.paint(canvas, Offset(labelX, size.height - 13));
    }
  }

  @override
  bool shouldRepaint(covariant SpectrumPainter oldDelegate) {
    return oldDelegate.isActive != isActive || oldDelegate.magnitudes != magnitudes;
  }
}
