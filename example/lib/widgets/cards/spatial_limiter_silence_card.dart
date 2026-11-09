import 'package:flutter/material.dart';
import '../../controllers/audio_engine_controller.dart';
import 'crossfeed_card.dart';
import 'dsp_effects_card.dart';

/// Legacy composite card combining [CrossfeedCard] and [DspEffectsCard].
///
/// In the modernized console architecture, crossfeed is decoupled into its own dedicated
/// [CrossfeedCard] while other dynamics and mastering processors reside in [DspEffectsCard].
class SpatialLimiterSilenceCard extends StatelessWidget {
  final AudioEngineController controller;

  const SpatialLimiterSilenceCard({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CrossfeedCard(controller: controller),
        const SizedBox(height: 12),
        DspEffectsCard(controller: controller),
      ],
    );
  }
}
