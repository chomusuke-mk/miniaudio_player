import 'package:flutter/material.dart';

import '../../controllers/audio_engine_controller.dart';
import '../../theme/studio_colors.dart';
import '../common/dsp_sub_card.dart';
import '../common/studio_card.dart';
import '../painters/eq_curve_painter.dart';

/// Sub-card module for the ISO 266 10-band parametric equalizer,
/// matching Smart Silence Skipping, Crossfeed, Widener, and Reverb inside [DspEffectsCard].
class EqualizerSubCard extends StatelessWidget {
  final AudioEngineController controller;

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

  static const List<({String key, String label})> presets = [
    (key: 'flat', label: 'Flat'),
    (key: 'rock', label: 'Rock'),
    (key: 'pop', label: 'Pop'),
    (key: 'jazz', label: 'Jazz'),
    (key: 'classical', label: 'Classical'),
    (key: 'bassBoost', label: 'Bass Boost'),
  ];

  const EqualizerSubCard({super.key, required this.controller});

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

  Widget _buildPresetDropdown(String currentPreset, bool enabled) {
    return DropdownButtonFormField<String>(
      key: ValueKey(currentPreset),
      initialValue: currentPreset,
      isExpanded: true,
      dropdownColor: const Color(0xFF0E1424),
      decoration: const InputDecoration(
        labelText: 'Preset',
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      ),
      items: [
        ...presets.map(
          (p) => DropdownMenuItem(
            value: p.key,
            child: Text(
              p.label,
              style: const TextStyle(fontSize: 10.5),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        DropdownMenuItem(
          value: 'custom',
          enabled: currentPreset == 'custom',
          child: Text(
            'Custom',
            style: TextStyle(
              fontSize: 10.5,
              fontStyle: FontStyle.italic,
              color: currentPreset == 'custom'
                  ? StudioColors.accentCyan
                  : StudioColors.textMuted,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
      onChanged: enabled
          ? (presetKey) {
              if (presetKey == null || presetKey == 'custom') return;
              controller.setEqualizerPreset(presetKey);
            }
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final eq = controller.currentEqualizer;
        final isEnabled = eq.enabled;
        final selected = controller.selectedPreset;
        final currentPreset = presets.any((p) => p.key == selected)
            ? selected
            : 'custom';
        final activePresetLabel = presets
                .where((p) => p.key == currentPreset)
                .map((p) => p.label)
                .firstOrNull ??
            'Custom';
        final bandsList = eq.toList();

        return DspSubCard(
          icon: Icons.tune,
          title: 'ISO 266 10-Band Equalizer',
          subtitle: isEnabled
              ? 'Active: $activePresetLabel • Direct Form II Transposed'
              : 'Inactive: DF2T SIMD 10-band parametric response',
          enabled: isEnabled,
          accentColor: StudioColors.accentCyan,
          onToggle: controller.setEqualizerEnabled,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildPresetDropdown(currentPreset, isEnabled),
              const SizedBox(height: 10),

              // Interactive Biquad Response Curve Graph with Frequency Nodes
              Builder(
                builder: (graphContext) {
                  const graphHeight = 130.0;
                  void handleInteraction(Offset localPosition) {
                    final box = graphContext.findRenderObject() as RenderBox?;
                    if (box == null || !box.hasSize) return;
                    _handleGraphInteraction(
                      localPosition,
                      Size(box.size.width, graphHeight),
                    );
                  }

                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (details) =>
                        handleInteraction(details.localPosition),
                    onPanUpdate: (details) =>
                        handleInteraction(details.localPosition),
                    child: Container(
                      height: graphHeight,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: StudioColors.cardBorder,
                          width: 1.0,
                        ),
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
              Row(
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
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Standalone Equalizer card wrapper kept for backwards compatibility;
/// the active studio console mounts [EqualizerSubCard] inside [DspEffectsCard].
class EqualizerCard extends StatelessWidget {
  final AudioEngineController controller;

  static const List<String> frequencyLabels = EqualizerSubCard.frequencyLabels;
  static const List<({String key, String label})> presets =
      EqualizerSubCard.presets;

  const EqualizerCard({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return StudioCard(
      icon: Icons.tune,
      title: 'ISO 266 10-BAND PARAMETRIC EQUALIZER',
      subtitle: 'Direct Form II Transposed (DF2T) SIMD • 0.00 dB Analytical Error',
      child: EqualizerSubCard(controller: controller),
    );
  }
}
