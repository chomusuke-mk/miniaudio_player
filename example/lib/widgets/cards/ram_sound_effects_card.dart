import 'package:flutter/material.dart';

import '../../controllers/audio_engine_controller.dart';
import '../../theme/studio_colors.dart';
import '../common/studio_badge.dart';
import '../common/studio_card.dart';

/// Card showcasing native RAM sound effects and voice pool management in Rust.
/// Demonstrates zero memory duplication in Dart and live memory tracking.
class RamSoundEffectsCard extends StatelessWidget {
  final AudioEngineController controller;

  const RamSoundEffectsCard({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final engine = controller.engine;

    return StreamBuilder<List<String>>(
      stream: engine.stream.loadedEffectIds,
      initialData: engine.state.loadedEffectIds,
      builder: (context, loadedSnap) {
        final loadedIds = loadedSnap.data ?? engine.state.loadedEffectIds;

        return StreamBuilder<int>(
          stream: engine.stream.allocatedRamBytes,
          initialData: engine.state.allocatedRamBytes,
          builder: (context, ramSnap) {
            final ramBytes = ramSnap.data ?? engine.state.allocatedRamBytes;
            final ramKb = (ramBytes / 1024).toStringAsFixed(1);

            return StudioCard(
              icon: Icons.memory,
              title: 'NATIVE RAM SOUND EFFECTS & MEMORY',
              subtitle: 'Zero Dart RAM Duplication • Rust Decoded Voice Pool',
              trailing: StudioBadge(
                label: '$ramKb KB RAM',
                color: ramBytes > 0
                    ? StudioColors.accentEmerald
                    : StudioColors.textMuted,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Real-Time Memory & Voices Telemetry Strip
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF070B14),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: StudioColors.cardBorder,
                        width: 1.0,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        Expanded(
                          child: _buildMetric(
                            label: 'RAM USAGE',
                            value: '$ramKb KB',
                            color: StudioColors.accentEmerald,
                          ),
                        ),
                        Container(
                          width: 1,
                          height: 26,
                          color: StudioColors.cardBorder,
                        ),
                        Expanded(
                          child: StreamBuilder<int>(
                            stream: engine.stream.activeVoicesCount,
                            initialData: engine.state.activeVoicesCount,
                            builder: (context, voicesSnap) {
                              final voices =
                                  voicesSnap.data ??
                                  engine.state.activeVoicesCount;
                              return _buildMetric(
                                label: 'VOICES',
                                value: '$voices',
                                color: voices > 0
                                    ? StudioColors.accentCyan
                                    : StudioColors.textSecondary,
                              );
                            },
                          ),
                        ),
                        Container(
                          width: 1,
                          height: 26,
                          color: StudioColors.cardBorder,
                        ),
                        Expanded(
                          child: _buildMetric(
                            label: 'SFX LOADED',
                            value: '${loadedIds.length}',
                            color: loadedIds.isNotEmpty
                                ? StudioColors.accentPurple
                                : StudioColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),

                  // Polyphonic SFX Trigger Buttons
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ElevatedButton.icon(
                        icon: const Icon(Icons.flash_on, size: 16),
                        label: const Text(
                          'Laser SFX (880Hz)',
                          style: TextStyle(fontSize: 11),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF132238),
                          foregroundColor: StudioColors.accentCyan,
                          side: const BorderSide(
                            color: StudioColors.accentCyan,
                            width: 0.8,
                          ),
                        ),
                        onPressed: loadedIds.contains('sfx_laser')
                            ? () => controller.playSampleEffect('sfx_laser')
                            : null,
                      ),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.notifications_active, size: 16),
                        label: const Text(
                          'Chime SFX (1320Hz)',
                          style: TextStyle(fontSize: 11),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF231438),
                          foregroundColor: StudioColors.accentPurple,
                          side: const BorderSide(
                            color: StudioColors.accentPurple,
                            width: 0.8,
                          ),
                        ),
                        onPressed: loadedIds.contains('sfx_chime')
                            ? () => controller.playSampleEffect('sfx_chime')
                            : null,
                      ),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.radio_button_checked, size: 16),
                        label: const Text(
                          'Beep SFX (440Hz)',
                          style: TextStyle(fontSize: 11),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF122822),
                          foregroundColor: StudioColors.accentEmerald,
                          side: const BorderSide(
                            color: StudioColors.accentEmerald,
                            width: 0.8,
                          ),
                        ),
                        onPressed: loadedIds.contains('sfx_beep')
                            ? () => controller.playSampleEffect('sfx_beep')
                            : null,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // Polyphony & Pitch Variation Quick Actions
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      ActionChip(
                        label: const Text(
                          'High Pitch (1.5x)',
                          style: TextStyle(fontSize: 10),
                        ),
                        backgroundColor: StudioColors.backgroundDark,
                        side: const BorderSide(color: StudioColors.cardBorder),
                        onPressed: loadedIds.contains('sfx_laser')
                            ? () => controller.playSampleEffect(
                                'sfx_laser',
                                pitch: 1.5,
                              )
                            : null,
                      ),
                      ActionChip(
                        label: const Text(
                          'Low Pitch (0.7x)',
                          style: TextStyle(fontSize: 10),
                        ),
                        backgroundColor: StudioColors.backgroundDark,
                        side: const BorderSide(color: StudioColors.cardBorder),
                        onPressed: loadedIds.contains('sfx_chime')
                            ? () => controller.playSampleEffect(
                                'sfx_chime',
                                pitch: 0.7,
                              )
                            : null,
                      ),
                      ActionChip(
                        label: const Text(
                          'Reload SFX',
                          style: TextStyle(fontSize: 10),
                        ),
                        backgroundColor: StudioColors.backgroundDark,
                        side: const BorderSide(color: StudioColors.accentCyan),
                        onPressed: controller.loadSampleEffects,
                      ),
                      ActionChip(
                        label: const Text(
                          'Unload All (0 KB)',
                          style: TextStyle(fontSize: 10),
                        ),
                        backgroundColor: StudioColors.backgroundDark,
                        side: const BorderSide(color: StudioColors.accentRose),
                        onPressed: loadedIds.isNotEmpty
                            ? controller.unloadAllEffects
                            : null,
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildMetric({
    required String label,
    required String value,
    required Color color,
  }) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: color,
            fontFamily: 'monospace',
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(
            fontSize: 8.5,
            fontWeight: FontWeight.w600,
            color: StudioColors.textMuted,
            letterSpacing: 0.5,
          ),
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
