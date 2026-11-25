import 'package:material_ui/material_ui.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../../core/theme/studio_colors.dart';
import '../../../shared/widgets/studio_badge.dart';
import '../../../shared/widgets/studio_card.dart';
import '../../console/controllers/audio_engine_controller.dart';
import 'input_capture_panel.dart';
import 'input_config_dialog.dart';
import 'output_matrix_panel.dart';

/// Controller-bound card managing multi-endpoint playback output routing and
/// multi-capture microphone inputs with sidechain auto-ducking.
class HardwareRoutingCard extends StatelessWidget {
  /// Controller exposing hardware enumeration streams and routing RPCs.
  final AudioEngineController controller;

  /// Creates a [HardwareRoutingCard] observing [controller].
  const HardwareRoutingCard({super.key, required this.controller});

  /// Opens [InputConfigDialog] for capture [device] inside [context] and
  /// forwards saved settings to [AudioEngineController.configureInputDevice].
  void _openInputConfigDialog(BuildContext context, AudioDevice device) {
    final curConfig = controller.getInputConfig(device.id);
    MapLogger.debug(
      '[ROUTING:UI] Opening input config modal for device "${device.displayName}" (${device.id})',
    );
    showDialog<void>(
      context: context,
      builder: (_) => InputConfigDialog(
        device: device,
        initialConfig: curConfig,
        onApply: (config) async {
          await controller.configureInputDevice(device.id, config);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<AudioDevice>>(
      stream: controller.engine.stream.globalOutputDevices,
      initialData: controller.engine.state.globalOutputDevices,
      builder: (context, outDevsSnap) {
        final outDevs =
            outDevsSnap.data ?? controller.engine.state.globalOutputDevices;

        return StreamBuilder<List<AudioDevice>>(
          stream: controller.engine.stream.globalInputDevices,
          initialData: controller.engine.state.globalInputDevices,
          builder: (context, inDevsSnap) {
            final inDevs =
                inDevsSnap.data ?? controller.engine.state.globalInputDevices;

            return StreamBuilder<Set<AudioOutput>>(
              stream: controller.engine.stream.outputs,
              initialData: controller.engine.state.outputs,
              builder: (context, outputsSnap) {
                final outputs =
                    outputsSnap.data ?? controller.engine.state.outputs;

                return StreamBuilder<Set<AudioInput>>(
                  stream: controller.engine.stream.inputs,
                  initialData: controller.engine.state.inputs,
                  builder: (context, inputsSnap) {
                    final inputs =
                        inputsSnap.data ?? controller.engine.state.inputs;

                    return ListenableBuilder(
                      listenable: controller.routingListenable,
                      builder: (context, _) {
                        return StudioCard(
                          icon: Icons.alt_route,
                          title: 'AUDIO HARDWARE ROUTING MATRIX',
                          subtitle:
                              'Multi-Destination Output Matrix • Multi-Capture Microphones with Auto-Ducking',
                          trailing: Wrap(
                            spacing: 6,
                            children: [
                              StudioBadge(
                                label: '${outputs.length} OUT',
                                color: outputs.isNotEmpty
                                    ? StudioColors.accentCyan
                                    : StudioColors.textMuted,
                              ),
                              StudioBadge(
                                label: '${inputs.length} IN',
                                color: inputs.isNotEmpty
                                    ? StudioColors.accentAmber
                                    : StudioColors.textMuted,
                              ),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              OutputMatrixPanel(
                                outputDevices: outDevs,
                                activeOutputs: outputs,
                                onToggleOutput: controller.toggleOutput,
                                onOutputSourceChanged:
                                    controller.setOutputSource,
                              ),
                              const SizedBox(height: 12),
                              InputCapturePanel(
                                inputDevices: inDevs,
                                activeInputs: inputs,
                                isDuckingActive:
                                    controller.engine.state.isDuckingActive,
                                micRmsStream:
                                    controller.engine.stream.micRmsLevel,
                                initialMicRmsLevel:
                                    controller.engine.state.micRmsLevel,
                                onToggleInput: controller.toggleInput,
                                onConfigureInput: (device) =>
                                    _openInputConfigDialog(context, device),
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}
