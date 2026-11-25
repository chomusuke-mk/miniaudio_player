import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../../core/preview/studio_preview.dart';
import '../../../core/theme/studio_colors.dart';
import '../../../shared/painters/spectrum_painter.dart';
import '../../../shared/painters/vu_meter_painter.dart';

/// Pure presentational widget pairing the 10-band FFT spectrum bar painter and
/// stereo L/R VU meter canvas without holding controller or engine references.
class SpectrumVisualizerPanel extends StatelessWidget {
  /// Reactive visualizer telemetry listenable feeding both painters.
  final ValueListenable<VisualizerData> dataListenable;

  /// Whether visualizer DSP rendering is active.
  final bool isActive;

  /// Creates a [SpectrumVisualizerPanel] driven by [dataListenable] with
  /// [isActive] visibility dimming.
  const SpectrumVisualizerPanel({
    super.key,
    required this.dataListenable,
    required this.isActive,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxWidth < 400 ? 150.0 : 170.0;

        return SizedBox(
          height: height,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 7,
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: SpectrumPainter(
                      dataListenable: dataListenable,
                      isActive: isActive,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 3,
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: VuMeterPainter(
                      dataListenable: dataListenable,
                      isActive: isActive,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Preview rendering [SpectrumVisualizerPanel] with sample 10-band FFT levels.
@StudioPreview(
  name: 'Spectrum & VU Panel',
  group: 'Visualizer',
  size: Size(480, 200),
)
Widget spectrumVisualizerPanelPreview() {
  final notifier = ValueNotifier<VisualizerData>(
    StudioPreviewData.sampleVisualizerData,
  );
  return Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: StudioColors.cardBackgroundDark,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: StudioColors.cardBorder),
    ),
    child: SpectrumVisualizerPanel(
      dataListenable: notifier,
      isActive: true,
    ),
  );
}
