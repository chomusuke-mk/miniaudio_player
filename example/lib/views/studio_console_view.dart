import 'package:flutter/material.dart';
import '../../controllers/audio_analyzer_controller.dart';
import '../../controllers/audio_engine_controller.dart';
import '../widgets/cards/algorithmic_reverb_card.dart';
import '../widgets/cards/audio_analyzer_card.dart';
import '../widgets/cards/equalizer_card.dart';
import '../widgets/cards/playback_engine_card.dart';
import '../widgets/cards/playlist_queue_card.dart';
import '../widgets/cards/spatial_limiter_silence_card.dart';
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
        PlaybackEngineCard(controller: playerController),
        PlaylistQueueCard(controller: playerController),
        SpectrumVisualizerCard(controller: playerController),
      ],
      rightColumn: [
        AudioAnalyzerCard(
          playerController: playerController,
          analyzerController: analyzerController,
        ),
        EqualizerCard(controller: playerController),
        AlgorithmicReverbCard(controller: playerController),
        SpatialLimiterSilenceCard(controller: playerController),
      ],
    );
  }
}
