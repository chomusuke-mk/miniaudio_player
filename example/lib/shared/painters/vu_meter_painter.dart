import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../core/preview/studio_preview.dart';
import '../../core/theme/studio_colors.dart';

/// Custom painter rendering segmented stereo L/R LED VU meters driven directly
/// by [dataListenable].
class VuMeterPainter extends CustomPainter {
  /// Reactive visualizer telemetry listenable supplying L/R RMS levels.
  final ValueListenable<VisualizerData> dataListenable;

  /// Whether meter LEDs light up with active signal levels.
  final bool isActive;

  /// Creates a [VuMeterPainter] listening to [dataListenable] with active state
  /// [isActive].
  VuMeterPainter({required this.dataListenable, this.isActive = true})
    : super(repaint: dataListenable);

  /// Cached dark background card fill paint.
  static final Paint _bgPaint = Paint()..color = const Color(0xFF0A0F1D);

  /// Reference dB tick labels, fractional Y positions, and accent colors.
  static const _ticks = [
    ('0dB', 0.20, StudioColors.accentRose),
    ('-6dB', 0.40, StudioColors.accentAmber),
    ('-18dB', 0.65, StudioColors.accentCyan),
    ('-36dB', 0.85, StudioColors.accentEmerald),
  ];

  /// Pre-lays out a [TextPainter] for static meter header and dB tick strings.
  static TextPainter _layoutLabel(String text, TextStyle style) {
    return TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  /// Cached header caption painter rendered at the top of the stereo meter.
  static final TextPainter _headerPainter = _layoutLabel(
    'STEREO PEAK / RMS',
    const TextStyle(
      color: StudioColors.textPrimary,
      fontSize: 9.0,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.5,
    ),
  );

  /// Cached tick label painters aligned beside vertical channel strips.
  static final List<TextPainter> _tickPainters = [
    for (final tick in _ticks)
      _layoutLabel(
        tick.$1,
        TextStyle(
          color: tick.$3.withValues(alpha: 0.7),
          fontSize: 7.5,
          fontWeight: FontWeight.w600,
        ),
      ),
  ];

  /// Cached `'L'` channel footer caption painter.
  static final TextPainter _leftChannelPainter = _layoutLabel(
    'L',
    const TextStyle(
      color: StudioColors.accentCyan,
      fontSize: 9.0,
      fontWeight: FontWeight.bold,
    ),
  );

  /// Cached `'R'` channel footer caption painter.
  static final TextPainter _rightChannelPainter = _layoutLabel(
    'R',
    const TextStyle(
      color: StudioColors.accentCyan,
      fontSize: 9.0,
      fontWeight: FontWeight.bold,
    ),
  );

  /// Cached illuminated LED segment paints ordered from peak red to nominal green.
  static final List<Paint> _litBandPaints = [
    Paint()
      ..color = StudioColors.accentRose
      ..style = PaintingStyle.fill,
    Paint()
      ..color = StudioColors.accentAmber
      ..style = PaintingStyle.fill,
    Paint()
      ..color = StudioColors.accentCyan
      ..style = PaintingStyle.fill,
    Paint()
      ..color = StudioColors.accentEmerald
      ..style = PaintingStyle.fill,
  ];

  /// Cached unlit/dimmed LED segment paints matching [_litBandPaints].
  static final List<Paint> _dimBandPaints = [
    Paint()
      ..color = StudioColors.accentRose.withValues(alpha: 0.15)
      ..style = PaintingStyle.fill,
    Paint()
      ..color = StudioColors.accentAmber.withValues(alpha: 0.15)
      ..style = PaintingStyle.fill,
    Paint()
      ..color = StudioColors.accentCyan.withValues(alpha: 0.15)
      ..style = PaintingStyle.fill,
    Paint()
      ..color = StudioColors.accentEmerald.withValues(alpha: 0.15)
      ..style = PaintingStyle.fill,
  ];

  /// Selects the preallocated lit or dim segment [Paint] matching [segFraction] and [isLit].
  static Paint _segmentPaint(double segFraction, bool isLit) {
    final int bandIdx;
    if (segFraction >= 0.85) {
      bandIdx = 0;
    } else if (segFraction >= 0.65) {
      bandIdx = 1;
    } else if (segFraction >= 0.35) {
      bandIdx = 2;
    } else {
      bandIdx = 3;
    }
    return isLit ? _litBandPaints[bandIdx] : _dimBandPaints[bandIdx];
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)),
      _bgPaint,
    );

    _headerPainter.paint(
      canvas,
      Offset((size.width - _headerPainter.width) / 2, 6),
    );

    for (int i = 0; i < _ticks.length; i++) {
      final y = size.height * _ticks[i].$2;
      _tickPainters[i].paint(canvas, Offset(8, y - 5));
    }

    final barTop = size.height * 0.18;
    final barBottom = size.height * 0.88;
    final totalBarHeight = barBottom - barTop;
    const barWidth = 14.0;

    final leftBarX = size.width * 0.45;
    final rightBarX = size.width * 0.72;
    final data = dataListenable.value;

    _drawMeterChannel(
      canvas,
      leftBarX,
      barTop,
      barWidth,
      totalBarHeight,
      isActive ? data.left : 0.0,
      _leftChannelPainter,
    );

    _drawMeterChannel(
      canvas,
      rightBarX,
      barTop,
      barWidth,
      totalBarHeight,
      isActive ? data.right : 0.0,
      _rightChannelPainter,
    );
  }

  /// Renders one 20-segment vertical LED ladder at [x], [top] for [level].
  void _drawMeterChannel(
    Canvas canvas,
    double x,
    double top,
    double width,
    double height,
    double level,
    TextPainter labelPainter,
  ) {
    const segmentCount = 20;
    final segmentHeight = (height - (segmentCount * 1.5)) / segmentCount;

    for (int i = 0; i < segmentCount; i++) {
      final segFraction = (segmentCount - 1 - i) / segmentCount;
      final segY = top + i * (segmentHeight + 1.5);
      final isLit = level >= segFraction;

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, segY, width, segmentHeight),
          const Radius.circular(2),
        ),
        _segmentPaint(segFraction, isLit),
      );
    }

    labelPainter.paint(
      canvas,
      Offset(x + (width - labelPainter.width) / 2, top + height + 3),
    );
  }

  @override
  bool shouldRepaint(covariant VuMeterPainter oldDelegate) {
    return oldDelegate.isActive != isActive ||
        oldDelegate.dataListenable != dataListenable;
  }
}

/// Preview rendering [VuMeterPainter] with active stereo meter bars.
@StudioPreview(
  name: 'Stereo VU Meter',
  group: 'Painters',
  size: Size(180, 190),
)
Widget vuMeterPainterPreview() {
  final listenable = ValueNotifier<VisualizerData>(
    StudioPreviewData.sampleVisualizerData,
  );
  return SizedBox(
    height: 160,
    width: 140,
    child: CustomPaint(
      painter: VuMeterPainter(dataListenable: listenable, isActive: true),
    ),
  );
}
