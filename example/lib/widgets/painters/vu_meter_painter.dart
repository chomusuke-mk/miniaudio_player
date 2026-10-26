import 'package:flutter/material.dart';
import '../../theme/studio_colors.dart';

class VuMeterPainter extends CustomPainter {
  final double leftLevel;
  final double rightLevel;
  final bool isActive;

  const VuMeterPainter({
    required this.leftLevel,
    required this.rightLevel,
    this.isActive = true,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final bgPaint = Paint()..color = const Color(0xFF0A0F1D);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)),
      bgPaint,
    );

    final textPainter = TextPainter(textDirection: TextDirection.ltr);

    // Header label
    textPainter.text = const TextSpan(
      text: 'STEREO PEAK / RMS',
      style: TextStyle(
        color: StudioColors.textPrimary,
        fontSize: 9.0,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.5,
      ),
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      Offset((size.width - textPainter.width) / 2, 6),
    );

    // dB ticks on the left: 0dB, -6dB, -18dB, -36dB
    const ticks = [
      ('0dB', 0.20, StudioColors.accentRose),
      ('-6dB', 0.40, StudioColors.accentAmber),
      ('-18dB', 0.65, StudioColors.accentCyan),
      ('-36dB', 0.85, StudioColors.accentEmerald),
    ];

    for (final tick in ticks) {
      final y = size.height * tick.$2;
      textPainter.text = TextSpan(
        text: tick.$1,
        style: TextStyle(
          color: tick.$3.withValues(alpha: 0.7),
          fontSize: 7.5,
          fontWeight: FontWeight.w600,
        ),
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(8, y - 5));
    }

    final barTop = size.height * 0.18;
    final barBottom = size.height * 0.88;
    final totalBarHeight = barBottom - barTop;
    const barWidth = 14.0;

    final leftBarX = size.width * 0.45;
    final rightBarX = size.width * 0.72;

    _drawMeterChannel(
      canvas,
      leftBarX,
      barTop,
      barWidth,
      totalBarHeight,
      isActive ? leftLevel : 0.0,
      'L',
    );

    _drawMeterChannel(
      canvas,
      rightBarX,
      barTop,
      barWidth,
      totalBarHeight,
      isActive ? rightLevel : 0.0,
      'R',
    );
  }

  void _drawMeterChannel(
    Canvas canvas,
    double x,
    double top,
    double width,
    double height,
    double level,
    String label,
  ) {
    const segmentCount = 20;
    final segmentHeight = (height - (segmentCount * 1.5)) / segmentCount;

    for (int i = 0; i < segmentCount; i++) {
      final segFraction = (segmentCount - 1 - i) / segmentCount;
      final segY = top + i * (segmentHeight + 1.5);
      final isLit = level >= segFraction;

      Color color;
      if (segFraction >= 0.85) {
        color = StudioColors.accentRose;
      } else if (segFraction >= 0.65) {
        color = StudioColors.accentAmber;
      } else if (segFraction >= 0.35) {
        color = StudioColors.accentCyan;
      } else {
        color = StudioColors.accentEmerald;
      }

      final paint = Paint()
        ..color = isLit ? color : color.withValues(alpha: 0.15)
        ..style = PaintingStyle.fill;

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, segY, width, segmentHeight),
          const Radius.circular(2),
        ),
        paint,
      );
    }

    // Channel label below
    final textPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(
          color: StudioColors.accentCyan,
          fontSize: 9.0,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    textPainter.paint(
      canvas,
      Offset(x + (width - textPainter.width) / 2, top + height + 3),
    );
  }

  @override
  bool shouldRepaint(covariant VuMeterPainter oldDelegate) {
    return oldDelegate.leftLevel != leftLevel ||
        oldDelegate.rightLevel != rightLevel ||
        oldDelegate.isActive != isActive;
  }
}
