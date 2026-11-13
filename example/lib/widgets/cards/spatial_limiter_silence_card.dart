import 'package:flutter/material.dart';

import '../../controllers/audio_engine_controller.dart';
import 'dsp_effects_card.dart';

/// Legacy wrapper preserved for backwards compatibility; all spatial, limiter,
/// silence skipping, and BS2B crossfeed controls reside inside [DspEffectsCard].
class SpatialLimiterSilenceCard extends StatelessWidget {
  final AudioEngineController controller;

  const SpatialLimiterSilenceCard({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return DspEffectsCard(controller: controller);
  }
}
