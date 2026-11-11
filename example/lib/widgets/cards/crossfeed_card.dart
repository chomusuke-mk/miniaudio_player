import 'package:flutter/material.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../controllers/audio_engine_controller.dart';
import '../../theme/studio_colors.dart';
import '../common/studio_badge.dart';
import '../common/studio_card.dart';

/// Dedicated Bauer Stereophonic-to-Binaural (BS2B) crossfeed filtering card.
///
/// Reduces headphone listening fatigue by simulating the natural acoustic
/// cross-bleeding of loudspeaker soundwaves between left and right ears.
class CrossfeedCard extends StatelessWidget {
  final AudioEngineController controller;

  const CrossfeedCard({super.key, required this.controller});

  String _detectPreset(Crossfeed cf) {
    if (!cf.enabled) return 'Off';
    if ((cf.cutoffHz - 700.0).abs() < 1.0 && (cf.feedDb - 4.5).abs() < 0.1) {
      return 'Moffat-Bauer';
    }
    if ((cf.cutoffHz - 700.0).abs() < 1.0 && (cf.feedDb - 6.0).abs() < 0.1) {
      return 'Chu Moy';
    }
    return 'Custom';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final cf = controller.crossfeed;
        final currentPreset = _detectPreset(cf);

        return StudioCard(
          icon: Icons.headphones,
          title: 'BAUER BS2B BINAURAL CROSSFEED',
          subtitle: 'Acoustic Left-Right Interaural Time & Amplitude Blending for Headphones',
          trailing: StudioBadge(
            label: cf.enabled ? currentPreset.toUpperCase() : 'BYPASS',
            color: cf.enabled
                ? StudioColors.accentCyan
                : StudioColors.textMuted,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. Master On/Off Switch & Presets Bar
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF0A0F1D),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: StudioColors.cardBorder,
                    width: 1.0,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.headphones,
                      size: 16,
                      color: cf.enabled
                          ? StudioColors.accentCyan
                          : StudioColors.textMuted,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Crossfeed Active',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                          Text(
                            cf.enabled
                                ? 'Simulating loudspeaker acoustic bleed (${cf.cutoffHz.round()}Hz, ${cf.feedDb.toStringAsFixed(1)}dB)'
                                : 'Disabled: pure discrete channel stereo isolation',
                            style: const TextStyle(
                              fontSize: 9.5,
                              color: StudioColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: cf.enabled,
                      activeThumbColor: StudioColors.accentCyan,
                      onChanged: (val) => controller.toggleCrossfeed(val),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),

              // 2. Preset Chips
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  ChoiceChip(
                    label: const Text(
                      'Off (Bypass)',
                      style: TextStyle(fontSize: 9.5),
                    ),
                    selected: !cf.enabled,
                    selectedColor: StudioColors.accentRose,
                    backgroundColor: StudioColors.backgroundDark,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    onSelected: (_) => controller.setCrossfeed(Crossfeed.off),
                  ),
                  ChoiceChip(
                    label: const Text(
                      'Moffat-Bauer (700Hz, 4.5dB)',
                      style: TextStyle(fontSize: 9.5),
                    ),
                    selected: cf.enabled && currentPreset == 'Moffat-Bauer',
                    selectedColor: StudioColors.accentCyan,
                    backgroundColor: StudioColors.backgroundDark,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    onSelected: (_) =>
                        controller.setCrossfeed(Crossfeed.moffatBauer),
                  ),
                  ChoiceChip(
                    label: const Text(
                      'Chu Moy (700Hz, 6.0dB)',
                      style: TextStyle(fontSize: 9.5),
                    ),
                    selected: cf.enabled && currentPreset == 'Chu Moy',
                    selectedColor: StudioColors.accentCyan,
                    backgroundColor: StudioColors.backgroundDark,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    onSelected: (_) =>
                        controller.setCrossfeed(Crossfeed.chuMoy),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // 3. Cutoff Frequency & Feed Level Controls
              Opacity(
                opacity: cf.enabled ? 1.0 : 0.45,
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF070B14),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: StudioColors.cardBorder),
                  ),
                  child: Column(
                    children: [
                      // Cutoff Frequency Slider
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Expanded(
                            child: Text(
                              'Lowpass Cutoff Frequency',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${cf.cutoffHz.round()} Hz',
                            style: const TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'monospace',
                              color: StudioColors.accentCyan,
                            ),
                          ),
                        ],
                      ),
                      Slider(
                        value: cf.cutoffHz.clamp(300.0, 2000.0),
                        min: 300.0,
                        max: 2000.0,
                        divisions: 34,
                        activeColor: StudioColors.accentCyan,
                        onChanged: cf.enabled
                            ? (v) => controller.setCrossfeedCutoff(v)
                            : null,
                      ),
                      const SizedBox(height: 4),

                      // Feed Level Slider
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Expanded(
                            child: Text(
                              'Crossfeed Level (Feed dB)',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${cf.feedDb.toStringAsFixed(1)} dB',
                            style: const TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'monospace',
                              color: StudioColors.accentCyan,
                            ),
                          ),
                        ],
                      ),
                      Slider(
                        value: cf.feedDb.clamp(1.0, 15.0),
                        min: 1.0,
                        max: 15.0,
                        divisions: 28,
                        activeColor: StudioColors.accentCyan,
                        onChanged: cf.enabled
                            ? (v) => controller.setCrossfeedFeed(v)
                            : null,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),

              // 4. Acoustic Binaural Bleed Visual Diagram
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF070B14),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: StudioColors.cardBorder,
                    width: 0.8,
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.compare_arrows,
                      size: 14,
                      color: StudioColors.accentCyan,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        cf.enabled
                            ? 'L ↔ R acoustic bleed: ~${(cf.feedDb / 15.0 * 100).round()}% blend below ${cf.cutoffHz.round()} Hz'
                            : 'Left and Right audio channels are completely isolated',
                        style: const TextStyle(
                          fontSize: 9.5,
                          color: StudioColors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
