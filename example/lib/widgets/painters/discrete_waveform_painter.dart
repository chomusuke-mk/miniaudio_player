import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Renders audio waveform as discrete, un-smoothed rectangular blocks.
///
/// Unlike continuous Bezier curve smoothers, this painter renders raw
/// acoustic amplitude peaks as distinct vertical rectangular bars.
class DiscreteWaveformPainter extends CustomPainter {
  final List<double> points;
  final Color barColor;
  final Color emptyColor;
  final double barGap;

  const DiscreteWaveformPainter({
    required this.points,
    required this.barColor,
    this.emptyColor = const Color(0xFF161F33),
    this.barGap = 1.5,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final centerY = size.height / 2;
    final maxHalfHeight = size.height / 2 * 0.95;

    if (points.isEmpty) {
      // Draw subtle placeholder rectangular bars across width
      final emptyPaint = Paint()..color = emptyColor;
      const placeholderWidth = 2.0;
      final step = placeholderWidth + barGap;
      final total = (size.width / step).floor();
      for (int i = 0; i < total; i++) {
        final x = i * step;
        canvas.drawRect(
          Rect.fromLTWH(x, centerY - 2.0, placeholderWidth, 4.0),
          emptyPaint,
        );
      }
      return;
    }

    final n = points.length;
    final totalGaps = (n - 1) * barGap;
    final barWidth = math.max(1.0, (size.width - totalGaps) / n);
    final effectiveGap = n > 1 ? (size.width - (n * barWidth)) / (n - 1) : 0.0;

    final barPaint = Paint()
      ..color = barColor
      ..style = PaintingStyle.fill;

    for (int i = 0; i < n; i++) {
      final x = i * (barWidth + effectiveGap);
      final rawPoint = points[i].clamp(0.0, 1.0);
      final amp = math.max(1.5, rawPoint * maxHalfHeight);
      final rect = Rect.fromLTWH(
        x,
        centerY - amp,
        barWidth,
        amp * 2,
      );
      canvas.drawRect(rect, barPaint);
    }
  }

  @override
  bool shouldRepaint(covariant DiscreteWaveformPainter oldDelegate) {
    return oldDelegate.points != points ||
        oldDelegate.barColor != barColor ||
        oldDelegate.emptyColor != emptyColor ||
        oldDelegate.barGap != barGap;
  }
}
