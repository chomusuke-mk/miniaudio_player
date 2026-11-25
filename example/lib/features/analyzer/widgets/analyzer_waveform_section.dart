import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../../core/preview/studio_preview.dart';
import '../../../core/theme/studio_colors.dart';
import '../../../shared/painters/discrete_waveform_painter.dart';

/// Pure sub-section displaying the discrete rectangular waveform profile and
/// peak/RMS/crest telemetry strip for an analyzed audio source.
class AnalyzerWaveformSection extends StatelessWidget {
  /// Normalized amplitude envelope points computed during single-pass decoding.
  final List<double> points;

  /// Whether acoustic analysis is currently in flight (`true` shows placeholders).
  final bool isLoading;

  /// Creates an [AnalyzerWaveformSection] plotting [points] with loading state
  /// [isLoading].
  const AnalyzerWaveformSection({
    super.key,
    required this.points,
    this.isLoading = false,
  });

  /// Builds a small inline telemetry badge with muted [label] and colored
  /// [value].
  Widget _buildMiniTelemetryBadge(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0F1D),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: StudioColors.cardBorder, width: 0.8),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(
                fontSize: 8,
                fontWeight: FontWeight.w600,
                color: StudioColors.textMuted,
              ),
            ),
            TextSpan(
              text: value,
              style: TextStyle(
                fontSize: 8.5,
                fontWeight: FontWeight.w700,
                fontFamily: 'monospace',
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Builds the summary telemetry row computing Peak, Mean RMS, Floor, and
  /// Crest Factor across normalized [points].
  Widget _buildWaveformTelemetryStrip(List<double> points) {
    final maxPt = points.reduce(math.max);
    final minPt = points.reduce(math.min);
    final meanRms = math.sqrt(
      points.fold<double>(0.0, (sum, p) => sum + p * p) / points.length,
    );
    final crestStr = meanRms > 0
        ? '${(20 * math.log(maxPt / meanRms) / math.ln10).toStringAsFixed(1)} dB'
        : '--';

    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        _buildMiniTelemetryBadge(
          'PEAK',
          '${(maxPt * 100).toStringAsFixed(0)}%',
          StudioColors.accentCyan,
        ),
        _buildMiniTelemetryBadge(
          'MEAN RMS',
          '${(meanRms * 100).toStringAsFixed(0)}%',
          StudioColors.accentViolet,
        ),
        _buildMiniTelemetryBadge(
          'FLOOR',
          '${(minPt * 100).toStringAsFixed(0)}%',
          StudioColors.textSecondary,
        ),
        _buildMiniTelemetryBadge('CREST', crestStr, StudioColors.accentEmerald),
        _buildMiniTelemetryBadge(
          'DECIMATION',
          '<= 2048 buckets',
          StudioColors.accentAmber,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF070B14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: StudioColors.cardBorder, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.graphic_eq,
                size: 14,
                color: StudioColors.accentCyan,
              ),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  'WAVEFORM PROFILE',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                    color: Colors.white,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (points.isNotEmpty && !isLoading)
                Text(
                  '${points.length} blocks',
                  style: const TextStyle(
                    fontSize: 8.5,
                    color: StudioColors.textMuted,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Normalized dynamic amplitude energy envelope over time. Rendered as discrete, un-smoothed rectangular blocks showing raw peak values per sample slice.',
            style: TextStyle(
              fontSize: 9,
              color: StudioColors.textMuted,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF0A0F1D),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: StudioColors.cardBorder, width: 0.8),
            ),
            child: (points.isEmpty || isLoading)
                ? Stack(
                    alignment: Alignment.center,
                    children: [
                      const CustomPaint(
                        size: Size.infinite,
                        painter: DiscreteWaveformPainter(
                          points: [],
                          barColor: StudioColors.accentCyan,
                        ),
                      ),
                      Text(
                        isLoading ? 'loading...' : '--',
                        style: TextStyle(
                          fontSize: 9.5,
                          color: isLoading
                              ? const Color(0xFF64748B)
                              : StudioColors.textMuted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  )
                : CustomPaint(
                    size: Size.infinite,
                    painter: DiscreteWaveformPainter(
                      points: points,
                      barColor: StudioColors.accentCyan,
                    ),
                  ),
          ),
          if (points.isNotEmpty && !isLoading) ...[
            const SizedBox(height: 8),
            _buildWaveformTelemetryStrip(points),
          ],
        ],
      ),
    );
  }
}

/// Preview rendering [AnalyzerWaveformSection] with sample amplitude bars.
@StudioPreview(
  name: 'Analyzer Waveform Section',
  group: 'Analyzer',
  size: Size(620, 190),
)
Widget analyzerWaveformSectionPreview() {
  return AnalyzerWaveformSection(points: StudioPreviewData.sampleWaveform);
}
