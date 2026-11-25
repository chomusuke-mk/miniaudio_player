import 'package:material_ui/material_ui.dart';

import '../../core/preview/studio_preview.dart';
import '../../core/theme/studio_colors.dart';

/// Renders a continuous smooth audio waveform contour layered with an unplayed
/// track background, backward/forward buffer halo, played progress fill, and
/// playhead scrubber indicator.
class WaveformPainter extends CustomPainter {
  /// Normalized amplitude envelope values in the range `0.0..1.0`.
  final List<double> points;

  /// Normalized playhead cursor position in `0.0..1.0`.
  final double progress;

  /// Normalized start fraction of the cached ring-buffer window.
  final double bufferStartProgress;

  /// Normalized end fraction of the cached ring-buffer window.
  final double bufferedProgress;

  /// Foreground accent color used for played waveform slices and cursor cap.
  final Color playedColor;

  /// Background color used for unplayed waveform regions.
  final Color unplayedColor;

  /// Creates a [WaveformPainter] rendering [points] with playhead [progress],
  /// buffer span [bufferStartProgress]..[bufferedProgress], [playedColor], and
  /// [unplayedColor].
  const WaveformPainter({
    required this.points,
    required this.progress,
    this.bufferStartProgress = 0.0,
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

    // 1. Build smooth continuous waveform path.
    final path = Path();
    if (n == 1) {
      final amp = calcAmp(points[0]);
      path.addRect(Rect.fromLTWH(0, centerY - amp, size.width, amp * 2));
    } else {
      final dx = size.width / (n - 1);

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

    // Layer 1: Unplayed waveform background.
    final unplayedPaint = Paint()
      ..color = unplayedColor
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, unplayedPaint);

    final unplayedStroke = Paint()
      ..color = unplayedColor.withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawPath(path, unplayedStroke);

    final clampedStart = bufferStartProgress.clamp(0.0, 1.0);
    final clampedBuffer = bufferedProgress.clamp(clampedStart, 1.0);
    final clampedProgress = progress.clamp(0.0, 1.0);
    final startX = size.width * clampedStart;
    final endX = size.width * clampedBuffer;
    final playheadX = size.width * clampedProgress;

    // Layer 2a: Preload buffer halo ahead of playhead.
    final aheadStartX = startX.clamp(playheadX, size.width);
    if (endX > aheadStartX) {
      canvas.save();
      canvas.clipRect(
        Rect.fromLTWH(aheadStartX, 0, endX - aheadStartX, size.height),
      );

      final bufferPaint = Paint()
        ..color = const Color(0x55FFFFFF)
        ..style = PaintingStyle.fill;
      canvas.drawPath(path, bufferPaint);

      final bufferStroke = Paint()
        ..color = const Color(0x88FFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;
      canvas.drawPath(path, bufferStroke);
      canvas.restore();
    }

    // Layer 3a: Unbuffered played history behind buffer start.
    final evictedEndX = playheadX.clamp(0.0, startX);
    if (evictedEndX > 0.0) {
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0, 0, evictedEndX, size.height));

      final evictedPaint = Paint()
        ..color = playedColor.withValues(alpha: 0.30)
        ..style = PaintingStyle.fill;
      canvas.drawPath(path, evictedPaint);

      final evictedStroke = Paint()
        ..color = playedColor.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;
      canvas.drawPath(path, evictedStroke);
      canvas.restore();
    }

    // Layer 3b: Buffered played section behind playhead.
    final backBufStartX = startX.clamp(0.0, playheadX);
    final backBufEndX = endX.clamp(backBufStartX, playheadX);
    if (backBufEndX > backBufStartX) {
      canvas.save();
      canvas.clipRect(
        Rect.fromLTWH(
          backBufStartX,
          0,
          backBufEndX - backBufStartX,
          size.height,
        ),
      );

      final playedPaint = Paint()
        ..color = playedColor
        ..style = PaintingStyle.fill;
      canvas.drawPath(path, playedPaint);

      final backHaloPaint = Paint()
        ..color = const Color(0x38FFFFFF)
        ..style = PaintingStyle.fill;
      canvas.drawPath(path, backHaloPaint);

      final playedStroke = Paint()
        ..color = Colors.white.withValues(alpha: 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1;
      canvas.drawPath(path, playedStroke);
      canvas.restore();
    }

    // Layer 3c: Played region ahead of buffered end.
    if (playheadX > endX) {
      canvas.save();
      canvas.clipRect(
        Rect.fromLTWH(endX, 0, playheadX - endX, size.height),
      );

      final tailPaint = Paint()
        ..color = playedColor.withValues(alpha: 0.30)
        ..style = PaintingStyle.fill;
      canvas.drawPath(path, tailPaint);
      canvas.restore();
    }

    // Layer 3d: Continuous bottom buffer rail.
    if (endX > startX) {
      final railTop = (size.height - 2.5).clamp(0.0, size.height);
      if (backBufEndX > backBufStartX) {
        final backRailPaint = Paint()
          ..color = const Color(0xDDFFFFFF)
          ..style = PaintingStyle.fill;
        canvas.drawRect(
          Rect.fromLTWH(
            backBufStartX,
            railTop,
            backBufEndX - backBufStartX,
            size.height - railTop,
          ),
          backRailPaint,
        );
      }
      if (endX > aheadStartX) {
        final fwdRailPaint = Paint()
          ..color = const Color(0x88FFFFFF)
          ..style = PaintingStyle.fill;
        canvas.drawRect(
          Rect.fromLTWH(
            aheadStartX,
            railTop,
            endX - aheadStartX,
            size.height - railTop,
          ),
          fwdRailPaint,
        );
      }
    }

    // Layer 4: Center baseline.
    final baselinePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.15)
      ..strokeWidth = 0.8;
    canvas.drawLine(
      Offset(0, centerY),
      Offset(size.width, centerY),
      baselinePaint,
    );

    // Layer 5: Playhead scrubber cursor.
    if (clampedProgress >= 0.0 && clampedProgress <= 1.0) {
      final clampedPlayheadX =
          (size.width * clampedProgress).clamp(0.0, size.width);
      final playheadPaint = Paint()
        ..color = Colors.white
        ..strokeWidth = 2.0;
      canvas.drawLine(
        Offset(clampedPlayheadX, 0),
        Offset(clampedPlayheadX, size.height),
        playheadPaint,
      );

      final capPaint = Paint()..color = playedColor;
      canvas.drawCircle(Offset(clampedPlayheadX, centerY), 3.5, capPaint);
      canvas.drawCircle(
        Offset(clampedPlayheadX, centerY),
        1.5,
        Paint()..color = Colors.white,
      );
    }
  }

  @override
  bool shouldRepaint(covariant WaveformPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.bufferStartProgress != bufferStartProgress ||
        oldDelegate.bufferedProgress != bufferedProgress ||
        oldDelegate.points != points ||
        oldDelegate.playedColor != playedColor ||
        oldDelegate.unplayedColor != unplayedColor;
  }
}

/// Preview rendering [WaveformPainter] with partial ring-buffer halo and cursor.
@StudioPreview(
  name: 'Waveform Scrubber Contour',
  group: 'Painters',
  size: Size(440, 80),
)
Widget waveformPainterPreview() {
  return Container(
    height: 48,
    width: double.infinity,
    decoration: BoxDecoration(
      color: const Color(0xFF070B14),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: StudioColors.cardBorder),
    ),
    child: CustomPaint(
      painter: WaveformPainter(
        points: StudioPreviewData.sampleWaveform,
        progress: 0.42,
        bufferStartProgress: 0.15,
        bufferedProgress: 0.72,
        playedColor: StudioColors.accentCyan,
        unplayedColor: StudioColors.cardBorderFocused,
      ),
    ),
  );
}
