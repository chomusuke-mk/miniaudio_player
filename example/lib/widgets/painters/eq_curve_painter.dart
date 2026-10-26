import 'package:flutter/material.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import '../../theme/studio_colors.dart';

class EqCurvePainter extends CustomPainter {
  final Equalizer equalizer;
  final Color activeColor;

  const EqCurvePainter({
    required this.equalizer,
    this.activeColor = StudioColors.accentCyan,
  });

  static const int bandCount = 10;

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

    // 1. Subtle grey horizontal center line for 0 dB
    final zeroLinePaint = Paint()
      ..color = const Color(0xFF26324A)
      ..strokeWidth = 1.2;
    canvas.drawLine(Offset(0, centerY), Offset(size.width, centerY), zeroLinePaint);

    // Subtle guide lines for +12 dB and -12 dB
    final guideLinePaint = Paint()
      ..color = const Color(0xFF1B2438)
      ..strokeWidth = 1.0;
    final topLimitY = centerY - verticalAmplitude;
    final bottomLimitY = centerY + verticalAmplitude;
    canvas.drawLine(Offset(0, topLimitY), Offset(size.width, topLimitY), guideLinePaint);
    canvas.drawLine(Offset(0, bottomLimitY), Offset(size.width, bottomLimitY), guideLinePaint);

    // 2. Internal left labels: +12dB (top), 0dB (center), -12dB (bottom)
    _drawInternalLabel(canvas, '+12dB', const Offset(8, 4));
    _drawInternalLabel(canvas, '0dB', Offset(8, centerY - 6));
    _drawInternalLabel(canvas, '-12dB', Offset(8, size.height - 18));

    // 3. Compute spline curve and band node positions
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

    // 4. Fill gradient under curve
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

    // 5. Stroke curve
    final strokePaint = Paint()
      ..color = activeColor
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke;
    canvas.drawPath(path, strokePaint);

    // 6. Draw dots/nodes on each frequency point
    for (int i = 0; i < nodePoints.length; i++) {
      final pt = nodePoints[i];

      // Subtle vertical projection guideline down towards center line
      final projPaint = Paint()
        ..color = activeColor.withValues(alpha: 0.25)
        ..strokeWidth = 1.0;
      canvas.drawLine(Offset(pt.dx, centerY), pt, projPaint);

      // Outer glow circle
      final glowPaint = Paint()
        ..color = activeColor.withValues(alpha: 0.4)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(pt, 6.0, glowPaint);

      // Inner solid point
      final pointPaint = Paint()
        ..color = activeColor
        ..style = PaintingStyle.fill;
      canvas.drawCircle(pt, 3.5, pointPaint);

      // Center white dot
      final centerDotPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill;
      canvas.drawCircle(pt, 1.5, centerDotPaint);
    }
  }

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
    return oldDelegate.equalizer != equalizer || oldDelegate.activeColor != activeColor;
  }
}
