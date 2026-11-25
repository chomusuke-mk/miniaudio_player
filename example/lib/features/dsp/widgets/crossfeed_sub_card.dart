import 'package:material_ui/material_ui.dart';

import '../../console/controllers/audio_engine_controller.dart';
import 'crossfeed_panel.dart';

/// Controller-bound sub-card wiring [AudioEngineController] Bauer BS2B
/// crossfeed state and callbacks into [CrossfeedPanel].
class BauerCrossfeedSubCard extends StatelessWidget {
  /// Controller providing crossfeed state and RPC setters.
  final AudioEngineController controller;

  /// Creates a [BauerCrossfeedSubCard] observing [controller].
  const BauerCrossfeedSubCard({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller.crossfeedListenable,
      builder: (context, _) {
        return CrossfeedPanel(
          crossfeed: controller.crossfeed,
          onToggle: controller.toggleCrossfeed,
          onPresetSelected: controller.setCrossfeed,
          onCutoffChanged: controller.setCrossfeedCutoff,
          onFeedChanged: controller.setCrossfeedFeed,
        );
      },
    );
  }
}
