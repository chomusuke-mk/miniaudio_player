import 'package:flutter/material.dart';

/// Renders a continuous, smooth audio waveform contour with:
/// 1. Unplayed background track.
/// 2. Preload buffer halo (translucent white, YouTube-style).
/// 3. Played active progress section (neon accent cyan).
/// 4. Playhead scrubber cursor.
class WaveformPainter extends CustomPainter {
  final List<double> points;
  final double progress;
  final double bufferedProgress;
  final Color playedColor;
  final Color unplayedColor;

  const WaveformPainter({
    required this.points,
    required this.progress,
    this.bufferedProgress = 0.0,
    required this.playedColor,
    required this.unplayedColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty || size.width <= 0 || size.height <= 0) return;

    final centerY = size.height / 2;
    final halfHeight = (size.height / 2) * 0.88;
    if (halfHeight <= 0) return;
    final minAmp = halfHeight < 1.5 ? halfHeight : 1.5;
    double calcAmp(double pt) =>
        (pt.clamp(0.05, 1.0) * halfHeight).clamp(minAmp, halfHeight);
    final n = points.length;

    // 1. Build smooth continuous waveform path
    final path = Path();
    if (n == 1) {
      final amp = calcAmp(points[0]);
      path.addRect(Rect.fromLTWH(0, centerY - amp, size.width, amp * 2));
    } else {
      final dx = size.width / (n - 1);

      // Top boundary
      path.moveTo(0, centerY);
      for (int i = 0; i < n; i++) {
        final x = i * dx;
        final amp = calcAmp(points[i]);
        final y = centerY - amp;
        if (i == 0) {
          path.lineTo(x, y);
        } else {
          final prevX = (i - 1) * dx;
          final prevAmp = calcAmp(points[i - 1]);
          final prevY = centerY - prevAmp;
          final midX = (prevX + x) / 2;
          final midY = (prevY + y) / 2;
          path.quadraticBezierTo(prevX, prevY, midX, midY);
        }
      }
      final lastAmp = calcAmp(points[n - 1]);
      path.lineTo(size.width, centerY - lastAmp);
      path.lineTo(size.width, centerY);

      // Bottom boundary (in reverse from n - 1 down to 0)
      for (int i = n - 1; i >= 0; i--) {
        final x = i * dx;
        final amp = calcAmp(points[i]);
        final y = centerY + amp;
        if (i == n - 1) {
          path.lineTo(x, y);
        } else {
          final nextX = (i + 1) * dx;
          final nextAmp = calcAmp(points[i + 1]);
          final nextY = centerY + nextAmp;
          final midX = (nextX + x) / 2;
          final midY = (nextY + y) / 2;
          path.quadraticBezierTo(nextX, nextY, midX, midY);
        }
      }
      final firstAmp = calcAmp(points[0]);
      path.lineTo(0, centerY + firstAmp);
      path.close();
    }

    // Layer 1: Background unplayed waveform track
    final unplayedPaint = Paint()
      ..color = unplayedColor
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, unplayedPaint);

    final unplayedStroke = Paint()
      ..color = unplayedColor.withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawPath(path, unplayedStroke);

    // Layer 2: Preload buffer halo (translucent white halo, like YouTube)
    final clampedBuffer = bufferedProgress.clamp(0.0, 1.0);
    if (clampedBuffer > 0.0) {
      canvas.save();
      canvas.clipRect(
        Rect.fromLTWH(0, 0, size.width * clampedBuffer, size.height),
      );

      final bufferPaint = Paint()
        ..color = const Color(0x55FFFFFF) // Soft white halo
        ..style = PaintingStyle.fill;
      canvas.drawPath(path, bufferPaint);

      final bufferStroke = Paint()
        ..color = const Color(0x88FFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;
      canvas.drawPath(path, bufferStroke);
      canvas.restore();
    }

    // Layer 3: Played waveform section (accent neon cyan)
    final clampedProgress = progress.clamp(0.0, 1.0);
    if (clampedProgress > 0.0) {
      canvas.save();
      canvas.clipRect(
        Rect.fromLTWH(0, 0, size.width * clampedProgress, size.height),
      );

      final playedPaint = Paint()
        ..color = playedColor
        ..style = PaintingStyle.fill;
      canvas.drawPath(path, playedPaint);

      final playedStroke = Paint()
        ..color = Colors.white.withValues(alpha: 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;
      canvas.drawPath(path, playedStroke);
      canvas.restore();
    }

    // Layer 4: Center baseline
    final baselinePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.15)
      ..strokeWidth = 0.8;
    canvas.drawLine(
      Offset(0, centerY),
      Offset(size.width, centerY),
      baselinePaint,
    );

    // Layer 5: Playhead scrubber indicator line
    if (clampedProgress >= 0.0 && clampedProgress <= 1.0) {
      final playheadX = (size.width * clampedProgress).clamp(0.0, size.width);
      final playheadPaint = Paint()
        ..color = Colors.white
        ..strokeWidth = 2.0;
      canvas.drawLine(
        Offset(playheadX, 0),
        Offset(playheadX, size.height),
        playheadPaint,
      );

      final capPaint = Paint()..color = playedColor;
      canvas.drawCircle(Offset(playheadX, centerY), 3.5, capPaint);
      canvas.drawCircle(
        Offset(playheadX, centerY),
        1.5,
        Paint()..color = Colors.white,
      );
    }
  }

  @override
  bool shouldRepaint(covariant WaveformPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.bufferedProgress != bufferedProgress ||
        oldDelegate.points != points ||
        oldDelegate.playedColor != playedColor ||
        oldDelegate.unplayedColor != unplayedColor;
  }
}
