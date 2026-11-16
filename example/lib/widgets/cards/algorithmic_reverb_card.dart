import 'package:flutter/material.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../controllers/audio_engine_controller.dart';
import '../../theme/studio_colors.dart';
import '../common/compact_slider_overlay.dart';
import '../common/dsp_sub_card.dart';
import '../common/studio_card.dart';

/// Sub-card module for Studio Algorithmic Reverberation (Freeverb model),
/// matching Smart Silence Skipping, Bauer BS2B Crossfeed, and Stereo Widener inside [DspEffectsCard].
class ReverbSubCard extends StatelessWidget {
  final AudioEngineController controller;

  static const List<String> reverbPresets = [
    'Small Room',
    'Studio',
    'Concert Hall',
    'Cathedral',
    'Plate',
    'Ambient',
  ];

  const ReverbSubCard({super.key, required this.controller});

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
        ...reverbPresets.map(
          (preset) => DropdownMenuItem(
            value: preset,
            child: Text(
              preset,
              style: const TextStyle(fontSize: 10.5),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        DropdownMenuItem(
          value: 'Custom',
          enabled: currentPreset == 'Custom',
          child: Text(
            'Custom',
            style: TextStyle(
              fontSize: 10.5,
              fontStyle: FontStyle.italic,
              color: currentPreset == 'Custom'
                  ? StudioColors.accentViolet
                  : StudioColors.textMuted,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
      onChanged: enabled
          ? (preset) {
              if (preset == null || preset == 'Custom') return;
              controller.setReverbPreset(preset);
            }
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller.reverbListenable,
      builder: (context, _) {
        final enabled = controller.reverbEnabled;
        final rawPreset = controller.selectedReverbPreset;
        final currentPreset = reverbPresets.contains(rawPreset)
            ? rawPreset
            : 'Custom';

        return DspSubCard(
          icon: Icons.account_balance,
          title: 'Algorithmic Reverb',
          subtitle: enabled
              ? 'Active: $currentPreset • Wet ${controller.reverbWet.toStringAsFixed(2)}x'
              : 'Freeverb 8-comb acoustic space simulation',
          enabled: enabled,
          accentColor: StudioColors.accentViolet,
          onToggle: controller.toggleReverb,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildPresetDropdown(currentPreset, enabled),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.start,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 6,
                runSpacing: 6,
                children: [
                  CompactSliderControl(
                    icon: Icons.open_in_full,
                    label:
                        'Room Size: ${controller.reverbRoomSize.toStringAsFixed(2)}',
                    valueFormatter: (v) => v.toStringAsFixed(2),
                    value: controller.reverbRoomSize.clamp(0.0, 1.0),
                    defaultValue: Reverb.studio.roomSize,
                    min: 0.0,
                    max: 1.0,
                    activeColor: StudioColors.accentCyan,
                    disabled: !enabled,
                    onChanged: (v) => controller.setReverbParams(roomSize: v),
                  ),
                  CompactSliderControl(
                    icon: Icons.blur_on,
                    label:
                        'Damping: ${controller.reverbDamping.toStringAsFixed(2)}',
                    valueFormatter: (v) => v.toStringAsFixed(2),
                    value: controller.reverbDamping.clamp(0.0, 1.0),
                    defaultValue: Reverb.studio.damping,
                    min: 0.0,
                    max: 1.0,
                    activeColor: StudioColors.accentViolet,
                    disabled: !enabled,
                    onChanged: (v) => controller.setReverbParams(damping: v),
                  ),
                  CompactSliderControl(
                    icon: Icons.swap_horiz,
                    label: 'Width: ${controller.reverbWidth.toStringAsFixed(2)}',
                    valueFormatter: (v) => v.toStringAsFixed(2),
                    value: controller.reverbWidth.clamp(0.0, 1.0),
                    defaultValue: Reverb.studio.width,
                    min: 0.0,
                    max: 1.0,
                    activeColor: StudioColors.accentEmerald,
                    disabled: !enabled,
                    onChanged: (v) => controller.setReverbParams(width: v),
                  ),
                  CompactSliderControl(
                    icon: Icons.water_drop,
                    label:
                        'Wet Level: ${controller.reverbWet.toStringAsFixed(2)}x',
                    valueFormatter: (v) => '${v.toStringAsFixed(2)}x',
                    value: controller.reverbWet.clamp(0.0, 2.0),
                    defaultValue: Reverb.studio.wet,
                    min: 0.0,
                    max: 2.0,
                    activeColor: StudioColors.accentAmber,
                    disabled: !enabled,
                    onChanged: (v) => controller.setReverbParams(wet: v),
                  ),
                  CompactSliderControl(
                    icon: Icons.waves,
                    label:
                        'Dry Level: ${controller.reverbDry.toStringAsFixed(2)}x',
                    valueFormatter: (v) => '${v.toStringAsFixed(2)}x',
                    value: controller.reverbDry.clamp(0.0, 2.0),
                    defaultValue: Reverb.studio.dry,
                    min: 0.0,
                    max: 2.0,
                    activeColor: const Color(0xFFFF5252),
                    disabled: !enabled,
                    onChanged: (v) => controller.setReverbParams(dry: v),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Standalone Freeverb reverb card wrapper kept for backwards compatibility;
/// the active studio console mounts [ReverbSubCard] inside [DspEffectsCard].
class AlgorithmicReverbCard extends StatelessWidget {
  final AudioEngineController controller;

  static const List<String> reverbPresets = ReverbSubCard.reverbPresets;

  const AlgorithmicReverbCard({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return StudioCard(
      icon: Icons.account_balance,
      title: 'STUDIO ALGORITHMIC REVERB (FREEVERB MODEL)',
      child: ReverbSubCard(controller: controller),
    );
  }
}
