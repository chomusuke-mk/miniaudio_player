import 'package:flutter/material.dart';
import '../../controllers/audio_engine_controller.dart';
import '../../theme/studio_colors.dart';
import '../common/compact_slider_overlay.dart';
import '../common/studio_badge.dart';
import '../common/studio_card.dart';
import '../painters/eq_curve_painter.dart';

class EqualizerCard extends StatelessWidget {
  final AudioEngineController controller;

  static const List<String> frequencyLabels = [
    '31', '63', '125', '250', '500', '1k', '2k', '4k', '8k', '16k'
  ];

  static const List<({String key, String label})> presets = [
    (key: 'flat', label: 'Flat'),
    (key: 'rock', label: 'Rock'),
    (key: 'pop', label: 'Pop'),
    (key: 'jazz', label: 'Jazz'),
    (key: 'classical', label: 'Classical'),
    (key: 'bassBoost', label: 'Bass Boost'),
  ];

  const EqualizerCard({super.key, required this.controller});

  void _handleGraphInteraction(Offset localPos, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    // Determine closest band
    int closestBand = 0;
    double minDistance = double.infinity;
    for (int i = 0; i < EqCurvePainter.bandCount; i++) {
      final bandX = EqCurvePainter.getXForBand(i, size.width);
      final dist = (bandX - localPos.dx).abs();
      if (dist < minDistance) {
        minDistance = dist;
        closestBand = i;
      }
    }

    // Determine gain from Y position
    final centerY = size.height / 2;
    final verticalAmplitude = size.height * 0.38;
    final normalized = -((localPos.dy - centerY) / verticalAmplitude);
    final gainDb = (normalized * 12.0).clamp(-12.0, 12.0);

    controller.setEqualizerBand(closestBand, gainDb);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final eq = controller.currentEqualizer;
        final selected = controller.selectedPreset;
        final bandsList = eq.toList();

        return StudioCard(
          icon: Icons.tune,
          title: 'ISO 266 10-BAND PARAMETRIC EQUALIZER',
          subtitle: 'Direct Form II Transposed (DF2T) SIMD • 0.00 dB Analytical Error',
          trailing: const StudioBadge(
            label: 'Acoustic RBJ Curves',
            color: StudioColors.accentCyan,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Presets Selection Chips & Right-Aligned Preamp Overlay Control
              LayoutBuilder(
                builder: (context, constraints) {
                  final isNarrow = constraints.maxWidth < 360;

                  final presetsScroll = SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        const Text(
                          'PRESETS: ',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: StudioColors.textSecondary,
                          ),
                        ),
                        const SizedBox(width: 4),
                        ...presets.map((p) {
                          final isSelected = selected == p.key;
                          return Padding(
                            padding: const EdgeInsets.only(right: 4.0),
                            child: ChoiceChip(
                              label: Text(
                                p.label,
                                style: TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: isSelected
                                      ? FontWeight.bold
                                      : FontWeight.w500,
                                  color: isSelected
                                      ? Colors.black
                                      : StudioColors.textSecondary,
                                ),
                              ),
                              selected: isSelected,
                              selectedColor: StudioColors.accentCyan,
                              backgroundColor: StudioColors.backgroundDark,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 0,
                              ),
                              visualDensity: VisualDensity.compact,
                              onSelected: (_) =>
                                  controller.setEqualizerPreset(p.key),
                            ),
                          );
                        }),
                      ],
                    ),
                  );

                  final preampControl = CompactSliderControl(
                    icon: Icons.tune,
                    label:
                        'Pre: ${controller.preampDb >= 0 ? '+' : ''}${controller.preampDb.toStringAsFixed(1)} dB',
                    value: controller.preampDb,
                    defaultValue: 0.0,
                    min: -12.0,
                    max: 12.0,
                    activeColor: StudioColors.accentAmber,
                    onChanged: controller.setPreamp,
                  );

                  if (isNarrow) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        presetsScroll,
                        const SizedBox(height: 6),
                        Align(
                          alignment: Alignment.centerRight,
                          child: preampControl,
                        ),
                      ],
                    );
                  }

                  return Row(
                    children: [
                      Expanded(child: presetsScroll),
                      const SizedBox(width: 8),
                      preampControl,
                    ],
                  );
                },
              ),
              const SizedBox(height: 10),

              // Interactive Biquad Response Curve Graph with Frequency Nodes
              LayoutBuilder(
                builder: (context, constraints) {
                  const graphHeight = 130.0;
                  final width = constraints.maxWidth;

                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (details) {
                      _handleGraphInteraction(details.localPosition, Size(width, graphHeight));
                    },
                    onPanUpdate: (details) {
                      _handleGraphInteraction(details.localPosition, Size(width, graphHeight));
                    },
                    child: Container(
                      height: graphHeight,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: StudioColors.cardBorder, width: 1.0),
                      ),
                      child: CustomPaint(
                        painter: EqCurvePainter(
                          equalizer: eq,
                          activeColor: StudioColors.accentCyan,
                        ),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 8),

              // Projections below each point outside the graph:
              // Line 1: Frequency in white
              // Line 2: Gain in accent cyan
              LayoutBuilder(
                builder: (context, constraints) {
                  return Row(
                    children: [
                      // Padding for left margin corresponding to (width / 11) * 0.5
                      const Expanded(flex: 1, child: SizedBox.shrink()),
                      for (int i = 0; i < EqCurvePainter.bandCount; i++) ...[
                        Expanded(
                          flex: 2,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Frequency label in pure white
                              Text(
                                frequencyLabels[i],
                                style: const TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                  fontFamily: 'monospace',
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              // Gain value in accent cyan
                              Text(
                                bandsList[i] > 0
                                    ? '+${bandsList[i].toStringAsFixed(1)}'
                                    : bandsList[i].toStringAsFixed(1),
                                style: TextStyle(
                                  fontSize: 8,
                                  fontWeight: FontWeight.w700,
                                  color: bandsList[i] != 0.0
                                      ? StudioColors.accentCyan
                                      : StudioColors.textMuted,
                                  fontFamily: 'monospace',
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                      const Expanded(flex: 1, child: SizedBox.shrink()),
                    ],
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}
