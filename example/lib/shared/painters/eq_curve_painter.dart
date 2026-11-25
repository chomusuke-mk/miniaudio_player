import 'package:material_ui/material_ui.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../core/preview/studio_preview.dart';
import '../../core/theme/studio_colors.dart';

/// Custom painter rendering the ISO 266 10-band parametric equalizer response
/// spline and interactive frequency nodes.
class EqCurvePainter extends CustomPainter {
  /// Equalizer band gains plotted along the horizontal frequency axis.
  final Equalizer equalizer;

  /// Accent color for the spline stroke, fill glow, and frequency nodes.
  final Color activeColor;

  /// Creates an [EqCurvePainter] visualizing [equalizer] with [activeColor].
  const EqCurvePainter({
    required this.equalizer,
    this.activeColor = StudioColors.accentCyan,
  });

  /// Total number of ISO 266 graphic equalizer bands (`10`).
  static const int bandCount = 10;

  /// Computes the canvas X coordinate for band [index] across total [width].
  static double getXForBand(int index, double width) {
    return (width / (bandCount + 1)) * (index + 1);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final bgPaint = Paint()..color = const Color(0xFF090D18);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)),
      bgPaint,
    );

    final centerY = size.height / 2;
    final verticalAmplitude = size.height * 0.38;

    // 1. Center 0 dB line and +/-12 dB reference rails.
    final zeroLinePaint = Paint()
      ..color = const Color(0xFF26324A)
      ..strokeWidth = 1.2;
    canvas.drawLine(
      Offset(0, centerY),
      Offset(size.width, centerY),
      zeroLinePaint,
    );

    final guideLinePaint = Paint()
      ..color = const Color(0xFF1B2438)
      ..strokeWidth = 1.0;
    final topLimitY = centerY - verticalAmplitude;
    final bottomLimitY = centerY + verticalAmplitude;
    canvas.drawLine(
      Offset(0, topLimitY),
      Offset(size.width, topLimitY),
      guideLinePaint,
    );
    canvas.drawLine(
      Offset(0, bottomLimitY),
      Offset(size.width, bottomLimitY),
      guideLinePaint,
    );

    // 2. Internal decibel axis labels.
    _drawInternalLabel(canvas, '+12dB', const Offset(8, 4));
    _drawInternalLabel(canvas, '0dB', Offset(8, centerY - 6));
    _drawInternalLabel(canvas, '-12dB', Offset(8, size.height - 18));

    // 3. Spline curve and band node coordinates.
    final path = Path();
    final fillPath = Path();
    final bands = equalizer.toList();
    final nodePoints = <Offset>[];

    final bandXPositions = <double>[];
    for (int i = 0; i < bandCount; i++) {
      bandXPositions.add(getXForBand(i, size.width));
    }

    path.moveTo(0, centerY);
    fillPath.moveTo(0, centerY);

    for (int i = 0; i < bandCount; i++) {
      final gain = bands[i].clamp(-12.0, 12.0);
      final y = centerY - (gain / 12.0) * verticalAmplitude;
      final x = bandXPositions[i];
      nodePoints.add(Offset(x, y));

      if (i == 0) {
        path.quadraticBezierTo(x * 0.5, centerY, x, y);
        fillPath.quadraticBezierTo(x * 0.5, centerY, x, y);
      } else {
        final prevX = bandXPositions[i - 1];
        final prevGain = bands[i - 1].clamp(-12.0, 12.0);
        final prevY = centerY - (prevGain / 12.0) * verticalAmplitude;
        final midX = (prevX + x) / 2;
        path.cubicTo(midX, prevY, midX, y, x, y);
        fillPath.cubicTo(midX, prevY, midX, y, x, y);
      }
    }

    path.lineTo(size.width, centerY);
    fillPath.lineTo(size.width, centerY);
    fillPath.close();

    // 4. Fill gradient beneath curve.
    final fillPaint = Paint()
      ..shader = LinearGradient(
        colors: [
          activeColor.withValues(alpha: 0.22),
          activeColor.withValues(alpha: 0.0),
        ],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ).createShader(Offset.zero & size)
      ..style = PaintingStyle.fill;
    canvas.drawPath(fillPath, fillPaint);

    // 5. Stroke response curve.
    final strokePaint = Paint()
      ..color = activeColor
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke;
    canvas.drawPath(path, strokePaint);

    // 6. Frequency nodes and vertical projection lines.
    for (int i = 0; i < nodePoints.length; i++) {
      final pt = nodePoints[i];

      final projPaint = Paint()
        ..color = activeColor.withValues(alpha: 0.25)
        ..strokeWidth = 1.0;
      canvas.drawLine(Offset(pt.dx, centerY), pt, projPaint);

      final glowPaint = Paint()
        ..color = activeColor.withValues(alpha: 0.4)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(pt, 6.0, glowPaint);

      final pointPaint = Paint()
        ..color = activeColor
        ..style = PaintingStyle.fill;
      canvas.drawCircle(pt, 3.5, pointPaint);

      final centerDotPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill;
      canvas.drawCircle(pt, 1.5, centerDotPaint);
    }
  }

  /// Paints a small monospace [text] label on [canvas] at [offset].
  void _drawInternalLabel(Canvas canvas, String text, Offset offset) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Color(0xFF6B7A99),
          fontSize: 8.5,
          fontWeight: FontWeight.w600,
          fontFamily: 'monospace',
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant EqCurvePainter oldDelegate) {
    return oldDelegate.equalizer != equalizer ||
        oldDelegate.activeColor != activeColor;
  }
}

/// Preview rendering [EqCurvePainter] using the built-in [Equalizer.rock] preset.
@StudioPreview(
  name: 'EQ Response Curve (Rock)',
  group: 'Painters',
  size: Size(440, 160),
)
Widget eqCurvePainterPreview() {
  return SizedBox(
    height: 130,
    width: double.infinity,
    child: CustomPaint(painter: EqCurvePainter(equalizer: Equalizer.rock)),
  );
}
