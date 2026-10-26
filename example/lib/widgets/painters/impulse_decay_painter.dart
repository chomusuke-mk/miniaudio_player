import 'dart:math';
import 'package:flutter/material.dart';
import '../../theme/studio_colors.dart';

class ImpulseDecayPainter extends CustomPainter {
  final double roomSize;
  final double damping;

  const ImpulseDecayPainter({
    required this.roomSize,
    required this.damping,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final bgPaint = Paint()..color = const Color(0xFF0A0F1D);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)),
      bgPaint,
    );

    final path = Path();
    final fillPath = Path();

    final decayRate = 1.0 + (1.0 - roomSize.clamp(0.1, 1.0)) * 5.0;
    final dampFactor = 1.0 + damping.clamp(0.0, 1.0) * 3.0;

    final centerY = size.height / 2;
    path.moveTo(8, centerY);
    fillPath.moveTo(8, centerY);

    const steps = 80;
    final dx = (size.width - 16) / steps;

    for (int i = 0; i <= steps; i++) {
      final t = i / steps;
      final x = 8 + (i * dx);
      // Damped oscillating exponential envelope
      final envelope = exp(-t * decayRate * dampFactor);
      final oscillation = sin(t * 40.0) * cos(t * 15.0);
      final amp = envelope * oscillation * (size.height * 0.42);
      final y = centerY - amp;

      if (i == 0) {
        path.moveTo(x, y);
        fillPath.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }

    fillPath.lineTo(size.width - 8, centerY);
    fillPath.close();

    final fillPaint = Paint()
      ..shader = LinearGradient(
        colors: [
          StudioColors.accentViolet.withValues(alpha: 0.35),
          StudioColors.accentCyan.withValues(alpha: 0.0),
        ],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ).createShader(Offset.zero & size)
      ..style = PaintingStyle.fill;

    canvas.drawPath(fillPath, fillPaint);

    final strokePaint = Paint()
      ..color = StudioColors.accentViolet
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    canvas.drawPath(path, strokePaint);

    // Center zero line
    final zeroLine = Paint()
      ..color = StudioColors.cardBorder
      ..strokeWidth = 1.0;
    canvas.drawLine(
      Offset(8, centerY),
      Offset(size.width - 8, centerY),
      zeroLine,
    );
  }

  @override
  bool shouldRepaint(covariant ImpulseDecayPainter oldDelegate) {
    return oldDelegate.roomSize != roomSize || oldDelegate.damping != damping;
  }
}
