import 'package:flutter/material.dart';

import '../../controllers/audio_analyzer_controller.dart';
import '../../controllers/audio_engine_controller.dart';
import '../widgets/cards/algorithmic_reverb_card.dart';
import '../widgets/cards/audio_analyzer_card.dart';
import '../widgets/cards/dsp_effects_card.dart';
import '../widgets/cards/equalizer_card.dart';
import '../widgets/cards/hardware_routing_card.dart';
import '../widgets/cards/playback_engine_card.dart';
import '../widgets/cards/playlist_queue_card.dart';
import '../widgets/cards/ram_sound_effects_card.dart';
import '../widgets/cards/spectrum_visualizer_card.dart';
import '../widgets/common/responsive_grid.dart';

class StudioConsoleView extends StatelessWidget {
  final AudioEngineController playerController;
  final AudioAnalyzerController analyzerController;

  const StudioConsoleView({
    super.key,
    required this.playerController,
    required this.analyzerController,
  });

  @override
  Widget build(BuildContext context) {
    return ResponsiveGrid(
      leftColumn: [
        RepaintBoundary(
          child: PlaybackEngineCard(
            controller: playerController,
            analyzerController: analyzerController,
          ),
        ),
        RepaintBoundary(
          child: PlaylistQueueCard(
            controller: playerController,
            analyzerController: analyzerController,
          ),
        ),
        RepaintBoundary(
          child: HardwareRoutingCard(controller: playerController),
        ),
        RepaintBoundary(
          child: SpectrumVisualizerCard(controller: playerController),
        ),
      ],
      rightColumn: [
        RepaintBoundary(
          child: AudioAnalyzerCard(
            playerController: playerController,
            analyzerController: analyzerController,
          ),
        ),
        RepaintBoundary(child: DspEffectsCard(controller: playerController)),
        RepaintBoundary(child: EqualizerCard(controller: playerController)),
        RepaintBoundary(
          child: AlgorithmicReverbCard(controller: playerController),
        ),
        RepaintBoundary(
          child: RamSoundEffectsCard(controller: playerController),
        ),
      ],
    );
  }
}
