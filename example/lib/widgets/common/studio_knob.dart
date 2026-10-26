import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../theme/studio_colors.dart';

/// Studio Console Rotary Knob / Circular Slider for Reverb & DSP parameters.
class StudioKnob extends StatefulWidget {
  final double value;
  final double min;
  final double max;
  final String label;
  final String? unit;
  final int decimals;
  final Color activeColor;
  final ValueChanged<double> onChanged;
  final double size;

  const StudioKnob({
    super.key,
    required this.value,
    this.min = 0.0,
    this.max = 1.0,
    required this.label,
    this.unit,
    this.decimals = 2,
    this.activeColor = StudioColors.accentPurple,
    required this.onChanged,
    this.size = 68.0,
  });

  @override
  State<StudioKnob> createState() => _StudioKnobState();
}

class _StudioKnobState extends State<StudioKnob> {
  double _dragAccumulator = 0;

  @override
  Widget build(BuildContext context) {
    final normalized = ((widget.value - widget.min) / (widget.max - widget.min))
        .clamp(0.0, 1.0);
    final valueText =
        '${widget.value.toStringAsFixed(widget.decimals)}${widget.unit ?? ''}';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onVerticalDragStart: (_) => _dragAccumulator = widget.value,
          onVerticalDragUpdate: (details) {
            // Dragging upwards increases value, downwards decreases
            final range = widget.max - widget.min;
            final sensitivity = range / 120.0;
            _dragAccumulator -= details.primaryDelta! * sensitivity;
            final clamped = _dragAccumulator.clamp(widget.min, widget.max);
            widget.onChanged(clamped);
          },
          child: Container(
            width: widget.size,
            height: widget.size,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFF0D1220),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                CustomPaint(
                  size: Size(widget.size, widget.size),
                  painter: _KnobPainter(
                    normalizedValue: normalized,
                    activeColor: widget.activeColor,
                    trackColor: StudioColors.cardBorderFocused,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(6.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        valueText,
                        style: TextStyle(
                          fontSize: widget.size > 60 ? 11 : 9.5,
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                          fontFamily: 'monospace',
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          widget.label,
          style: const TextStyle(
            fontSize: 8.5,
            fontWeight: FontWeight.w700,
            color: StudioColors.textSecondary,
            letterSpacing: 0.3,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class _KnobPainter extends CustomPainter {
  final double normalizedValue;
  final Color activeColor;
  final Color trackColor;

  const _KnobPainter({
    required this.normalizedValue,
    required this.activeColor,
    required this.trackColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - 8) / 2;
    const startAngle = 0.75 * math.pi; // 135 deg
    const sweepRange = 1.5 * math.pi;  // 270 deg

    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;

    final activePaint = Paint()
      ..color = activeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0
      ..strokeCap = StrokeCap.round;

    // Draw background arc
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepRange,
      false,
      trackPaint,
    );

    // Draw active arc
    final activeSweep = sweepRange * normalizedValue;
    if (activeSweep > 0.01) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        activeSweep,
        false,
        activePaint,
      );

      // Indicator tip dot
      final tipAngle = startAngle + activeSweep;
      final tipOffset = Offset(
        center.dx + radius * math.cos(tipAngle),
        center.dy + radius * math.sin(tipAngle),
      );
      final tipPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill;
      canvas.drawCircle(tipOffset, 2.5, tipPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _KnobPainter oldDelegate) {
    return oldDelegate.normalizedValue != normalizedValue ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.trackColor != trackColor;
  }
}
