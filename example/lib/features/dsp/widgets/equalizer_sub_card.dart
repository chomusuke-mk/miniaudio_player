import 'package:material_ui/material_ui.dart';

import '../../console/controllers/audio_engine_controller.dart';
import 'equalizer_panel.dart';

/// Controller-bound sub-card wiring [AudioEngineController] ISO 266 10-band
/// equalizer state and band/preset setters into [EqualizerPanel].
class EqualizerSubCard extends StatelessWidget {
  /// Controller providing equalizer state and DSP parameter setters.
  final AudioEngineController controller;

  /// Creates an [EqualizerSubCard] observing [controller].
  const EqualizerSubCard({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller.equalizerListenable,
      builder: (context, _) {
        return EqualizerPanel(
          equalizer: controller.currentEqualizer,
          selectedPreset: controller.selectedPreset,
          onToggle: controller.setEqualizerEnabled,
          onPresetChanged: controller.setEqualizerPreset,
          onBandChanged: controller.setEqualizerBand,
        );
      },
    );
  }
}
