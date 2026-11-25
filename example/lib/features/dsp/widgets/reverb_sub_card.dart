import 'package:material_ui/material_ui.dart';

import '../../console/controllers/audio_engine_controller.dart';
import 'reverb_panel.dart';

/// Controller-bound sub-card wiring [AudioEngineController] algorithmic Freeverb
/// state and setters into [ReverbPanel].
class ReverbSubCard extends StatelessWidget {
  /// Controller providing reverb state and parameter setters.
  final AudioEngineController controller;

  /// Creates a [ReverbSubCard] observing [controller].
  const ReverbSubCard({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller.reverbListenable,
      builder: (context, _) {
        return ReverbPanel(
          enabled: controller.reverbEnabled,
          selectedPreset: controller.selectedReverbPreset,
          roomSize: controller.reverbRoomSize,
          damping: controller.reverbDamping,
          width: controller.reverbWidth,
          wet: controller.reverbWet,
          dry: controller.reverbDry,
          onToggle: controller.toggleReverb,
          onPresetChanged: controller.setReverbPreset,
          onRoomSizeChanged: (value) =>
              controller.setReverbParams(roomSize: value),
          onDampingChanged: (value) =>
              controller.setReverbParams(damping: value),
          onWidthChanged: (value) => controller.setReverbParams(width: value),
          onWetChanged: (value) => controller.setReverbParams(wet: value),
          onDryChanged: (value) => controller.setReverbParams(dry: value),
        );
      },
    );
  }
}
