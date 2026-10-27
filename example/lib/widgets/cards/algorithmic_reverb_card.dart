import 'package:flutter/material.dart';
import '../../controllers/audio_engine_controller.dart';
import '../../theme/studio_colors.dart';
import '../common/studio_badge.dart';
import '../common/studio_card.dart';
import '../common/studio_knob.dart';

class AlgorithmicReverbCard extends StatelessWidget {
  final AudioEngineController controller;

  static const List<String> reverbPresets = [
    'Concert Hall',
    'Small Room',
    'Studio',
    'Cathedral',
    'Plate',
    'Ambient',
    'Off',
  ];

  const AlgorithmicReverbCard({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final activePreset = controller.selectedReverbPreset;

        return StudioCard(
          icon: Icons.account_balance,
          title: 'STUDIO ALGORITHMIC REVERB (FREEVERB MODEL)',
          subtitle: '8 Comb LPF + 4 Allpass per Channel • Discrete Wet/Dry Rotary Engine',
          trailing: const StudioBadge(
            label: 'O(1) Real-Time',
            color: StudioColors.accentViolet,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Presets selector chips
              SingleChildScrollView(
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
                    ...reverbPresets.map((preset) {
                      final isSelected = activePreset == preset;
                      return Padding(
                        padding: const EdgeInsets.only(right: 4.0),
                        child: ChoiceChip(
                          label: Text(
                            preset,
                            style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                              color: isSelected ? Colors.black : StudioColors.textSecondary,
                            ),
                          ),
                          selected: isSelected,
                          selectedColor: StudioColors.accentViolet,
                          backgroundColor: StudioColors.cardBackgroundDark,
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 0),
                          visualDensity: VisualDensity.compact,
                          onSelected: (_) => controller.setReverbPreset(preset),
                        ),
                      );
                    }),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // 5 Rotary Studio Knobs (Rotary Sliders):
              // Room Size, Damping, Stereo Width, Wet Level, Dry Level
              LayoutBuilder(
                builder: (context, constraints) {
                  final isCompact = constraints.maxWidth < 420;

                  final knobs = [
                    StudioKnob(
                      label: 'ROOM SIZE',
                      value: controller.reverbRoomSize,
                      min: 0.0,
                      max: 1.0,
                      activeColor: StudioColors.accentCyan,
                      onChanged: (val) => controller.setReverbParams(roomSize: val),
                    ),
                    StudioKnob(
                      label: 'DAMPING',
                      value: controller.reverbDamping,
                      min: 0.0,
                      max: 1.0,
                      activeColor: StudioColors.accentViolet,
                      onChanged: (val) => controller.setReverbParams(damping: val),
                    ),
                    StudioKnob(
                      label: 'WIDTH',
                      value: controller.reverbWidth,
                      min: 0.0,
                      max: 1.0,
                      activeColor: StudioColors.accentEmerald,
                      onChanged: (val) => controller.setReverbParams(width: val),
                    ),
                    StudioKnob(
                      label: 'WET LEVEL',
                      value: controller.reverbWet,
                      min: 0.0,
                      max: 2.0,
                      unit: 'x',
                      activeColor: StudioColors.accentAmber,
                      onChanged: (val) => controller.setReverbParams(wet: val),
                    ),
                    StudioKnob(
                      label: 'DRY LEVEL',
                      value: controller.reverbDry,
                      min: 0.0,
                      max: 2.0,
                      unit: 'x',
                      activeColor: const Color(0xFFFF5252),
                      onChanged: (val) => controller.setReverbParams(dry: val),
                    ),
                  ];

                  if (isCompact) {
                    return Wrap(
                      alignment: WrapAlignment.spaceEvenly,
                      runAlignment: WrapAlignment.center,
                      spacing: 12,
                      runSpacing: 12,
                      children: knobs,
                    );
                  }

                  return Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: knobs,
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
