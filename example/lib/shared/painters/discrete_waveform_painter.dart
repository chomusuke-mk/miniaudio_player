import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../core/preview/studio_preview.dart';
import '../../core/theme/studio_colors.dart';

/// Renders an audio waveform as discrete, un-smoothed rectangular amplitude bars.
class DiscreteWaveformPainter extends CustomPainter {
  /// Normalized waveform amplitude samples in `0.0..1.0`.
  final List<double> points;

  /// Fill color applied to amplitude bars when [points] is non-empty.
  final Color barColor;

  /// Placeholder bar fill color drawn when [points] is empty.
  final Color emptyColor;

  /// Horizontal gap in logical pixels separating adjacent bars.
  final double barGap;

  /// Creates a [DiscreteWaveformPainter] for [points] using [barColor],
  /// [emptyColor], and [barGap].
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
      final rect = Rect.fromLTWH(x, centerY - amp, barWidth, amp * 2);
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

/// Preview rendering [DiscreteWaveformPainter] with populated amplitude bars.
@StudioPreview(
  name: 'Discrete Waveform Bars',
  group: 'Painters',
  size: Size(440, 88),
)
Widget discreteWaveformPainterPreview() {
  return Container(
    height: 56,
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    decoration: BoxDecoration(
      color: const Color(0xFF0A0F1D),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: StudioColors.cardBorder),
    ),
    child: CustomPaint(
      painter: DiscreteWaveformPainter(
        points: StudioPreviewData.sampleWaveform,
        barColor: StudioColors.accentCyan,
      ),
    ),
  );
}
