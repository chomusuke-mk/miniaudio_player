import 'package:material_ui/material_ui.dart';

import '../../../shared/widgets/responsive_grid.dart';
import '../../analyzer/controllers/audio_analyzer_controller.dart';
import '../../dsp/widgets/dsp_effects_card.dart';
import '../../playback/widgets/playback_engine_card.dart';
import '../../queue/widgets/playlist_queue_card.dart';
import '../../routing/widgets/hardware_routing_card.dart';
import '../../sound_effects/widgets/ram_sound_effects_card.dart';
import '../../visualizer/widgets/spectrum_visualizer_card.dart';
import '../controllers/audio_engine_controller.dart';

/// Main Studio Master Console workspace arranging playback, queue, RAM sound
/// effects, hardware routing matrix, spectrum visualizer, and DSP mastering cards
/// into responsive multi-column grids.
class StudioConsoleView extends StatelessWidget {
  /// Primary audio engine controller driving playback, routing, and DSP state.
  final AudioEngineController playerController;

  /// Acoustic analyzer controller providing static analysis and ReplayGain sync.
  final AudioAnalyzerController analyzerController;

  /// Creates a [StudioConsoleView] connected to [playerController] and
  /// [analyzerController].
  const StudioConsoleView({
    super.key,
    required this.playerController,
    required this.analyzerController,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ResponsiveGrid.multi(
          columns: [
            ResponsiveColumnGroup(
              flex: 2,
              children: [
                RepaintBoundary(
                  child: PlaybackEngineCard(
                    controller: playerController,
                    analyzerController: analyzerController,
                  ),
                ),
              ],
            ),
            ResponsiveColumnGroup(
              flex: 2,
              children: [
                RepaintBoundary(
                  child: PlaylistQueueCard(
                    controller: playerController,
                    analyzerController: analyzerController,
                  ),
                ),
              ],
            ),
            ResponsiveColumnGroup(
              flex: 1,
              children: [
                RepaintBoundary(
                  child: RamSoundEffectsCard(controller: playerController),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 16),
        ResponsiveGrid(
          leftFlex: 1,
          rightFlex: 2,
          leftColumn: [
            RepaintBoundary(
              child: HardwareRoutingCard(controller: playerController),
            ),
            RepaintBoundary(
              child: SpectrumVisualizerCard(controller: playerController),
            ),
          ],
          rightColumn: [
            RepaintBoundary(
              child: DspEffectsCard(controller: playerController),
            ),
          ],
        ),
      ],
    );
  }
}
