import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../core/preview/studio_preview.dart';
import '../../core/theme/studio_colors.dart';

/// Custom painter rendering the real-time 10-band spectrum analyzer bars, peak
/// caps, and decibel grid lines driven directly by [dataListenable].
class SpectrumPainter extends CustomPainter {
  /// Reactive visualizer telemetry listenable driving frame repaints.
  final ValueListenable<VisualizerData> dataListenable;

  /// Whether visualizer bars should render live magnitudes instead of idle floor.
  final bool isActive;

  /// Creates a [SpectrumPainter] bound to [dataListenable] with active state
  /// [isActive].
  SpectrumPainter({required this.dataListenable, this.isActive = true})
    : super(repaint: dataListenable);

  /// Center frequencies (Hz) displayed below the ten spectrum bars.
  static const List<String> frequencyLabels = [
    '31',
    '63',
    '125',
    '250',
    '500',
    '1k',
    '2k',
    '4k',
    '8k',
    '16k',
  ];

  /// Reference dB grid line labels paired with normalized vertical offsets.
  static const List<(String, double)> _dbLevels = [
    ('0 dB', 0.15),
    ('-12 dB', 0.40),
    ('-24 dB', 0.65),
    ('-36 dB', 0.90),
  ];

  /// Cached dark background canvas fill paint.
  static final Paint _bgPaint = Paint()..color = const Color(0xFF0A0F1D);

  /// Cached subtle horizontal reference grid line paint.
  static final Paint _gridPaint = Paint()
    ..color = StudioColors.cardBorder.withValues(alpha: 0.6)
    ..strokeWidth = 1.0;

  /// Cached peak-cap horizontal highlight stroke paint.
  static final Paint _capPaint = Paint()
    ..color = Colors.white.withValues(alpha: 0.9)
    ..strokeWidth = 1.5;

  /// Reusable fill paint shaded per band gradient on every repaint.
  static final Paint _barPaint = Paint()..style = PaintingStyle.fill;

  /// Pre-lays out a [TextPainter] for static grid and frequency axis labels.
  static TextPainter _layoutLabel(String text, TextStyle style) {
    return TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  /// Cached decibel scale axis [TextPainter] instances.
  static final List<TextPainter> _dbLabelPainters = [
    for (final level in _dbLevels)
      _layoutLabel(
        level.$1,
        const TextStyle(
          color: StudioColors.textMuted,
          fontSize: 8.0,
          fontWeight: FontWeight.w600,
        ),
      ),
  ];

  /// Cached bright ISO frequency axis labels rendered while active.
  static final List<TextPainter> _activeFreqPainters = [
    for (final label in frequencyLabels)
      _layoutLabel(
        label,
        const TextStyle(
          color: StudioColors.textSecondary,
          fontSize: 8.0,
          fontWeight: FontWeight.w700,
        ),
      ),
  ];

  /// Cached muted ISO frequency axis labels rendered while idle/bypassed.
  static final List<TextPainter> _inactiveFreqPainters = [
    for (final label in frequencyLabels)
      _layoutLabel(
        label,
        const TextStyle(
          color: StudioColors.textMuted,
          fontSize: 8.0,
          fontWeight: FontWeight.w700,
        ),
      ),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)),
      _bgPaint,
    );

    for (int i = 0; i < _dbLevels.length; i++) {
      final y = size.height * _dbLevels[i].$2;
      canvas.drawLine(Offset(28, y), Offset(size.width - 6, y), _gridPaint);
      _dbLabelPainters[i].paint(canvas, Offset(2, y - 5));
    }

    final barAreaWidth = size.width - 34;
    const bandCount = 10;
    final totalBarSpacing = barAreaWidth * 0.25;
    final barSpacing = totalBarSpacing / (bandCount + 1);
    final barWidth = (barAreaWidth - totalBarSpacing) / bandCount;

    final magnitudes = dataListenable.value.bands;
    final barGradient = StudioColors.spectrumGradient;
    final freqPainters = isActive
        ? _activeFreqPainters
        : _inactiveFreqPainters;

    for (int i = 0; i < bandCount; i++) {
      final mag = (i < magnitudes.length && isActive)
          ? magnitudes[i].clamp(0.0, 1.0)
          : 0.05;

      final x = 32 + (i * (barWidth + barSpacing)) + barSpacing;
      final barHeight = max(4.0, (size.height - 24) * mag);
      final y = size.height - 18 - barHeight;

      final rect = Rect.fromLTWH(x, y, barWidth, barHeight);
      _barPaint.shader = barGradient.createShader(rect);

      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(3)),
        _barPaint,
      );

      if (isActive && mag > 0.1) {
        canvas.drawLine(
          Offset(x, y - 2),
          Offset(x + barWidth, y - 2),
          _capPaint,
        );
      }

      final labelPainter = freqPainters[i];
      final labelX = x + (barWidth - labelPainter.width) / 2;
      labelPainter.paint(canvas, Offset(labelX, size.height - 13));
    }
  }

  @override
  bool shouldRepaint(covariant SpectrumPainter oldDelegate) {
    return oldDelegate.isActive != isActive ||
        oldDelegate.dataListenable != dataListenable;
  }
}

/// Preview rendering [SpectrumPainter] with sample 10-band magnitudes.
@StudioPreview(
  name: 'Spectrum Analyzer (10-Band)',
  group: 'Painters',
  size: Size(360, 190),
)
Widget spectrumPainterPreview() {
  final listenable = ValueNotifier<VisualizerData>(
    StudioPreviewData.sampleVisualizerData,
  );
  return SizedBox(
    height: 160,
    width: double.infinity,
    child: CustomPaint(
      painter: SpectrumPainter(dataListenable: listenable, isActive: true),
    ),
  );
}
