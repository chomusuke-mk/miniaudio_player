import 'package:material_ui/material_ui.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../../core/preview/studio_preview.dart';
import '../../../core/theme/studio_colors.dart';
import '../../../shared/widgets/studio_badge.dart';

/// Pure presentational capture input matrix rendering microphone selection
/// toggles, live dBFS metering for active captures, ducking status, and
/// per-device configuration triggers.
class InputCapturePanel extends StatelessWidget {
  /// Discovered global microphone / line capture devices.
  final List<AudioDevice> inputDevices;

  /// Currently armed input endpoints.
  final Set<AudioInput> activeInputs;

  /// Whether voice auto-ducking is currently attenuating playback.
  final bool isDuckingActive;

  /// Optional live RMS input meter stream shared across active captures.
  final Stream<double>? micRmsStream;

  /// Fallback RMS reading in dBFS used before stream emissions arrive.
  final double initialMicRmsLevel;

  /// Invoked when the user toggles capture for [device].
  final ValueChanged<AudioDevice> onToggleInput;

  /// Invoked when the user clicks the gear icon to configure [device].
  final ValueChanged<AudioDevice> onConfigureInput;

  /// Creates an [InputCapturePanel] rendering [inputDevices], [activeInputs],
  /// [isDuckingActive], and live [micRmsStream] metering with [onToggleInput]
  /// and [onConfigureInput] actions.
  const InputCapturePanel({
    super.key,
    required this.inputDevices,
    required this.activeInputs,
    required this.isDuckingActive,
    this.micRmsStream,
    this.initialMicRmsLevel = -100.0,
    required this.onToggleInput,
    required this.onConfigureInput,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.mic, size: 14, color: StudioColors.accentAmber),
            const SizedBox(width: 6),
            const Expanded(
              child: Text(
                'CAPTURE INPUT SOURCES (MULTI-SELECT)',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: StudioColors.accentAmber,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (isDuckingActive) ...[
              const SizedBox(width: 4),
              const StudioBadge(
                label: 'DUCKING ACTIVE',
                color: StudioColors.accentAmber,
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFF070B14),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: StudioColors.cardBorder),
          ),
          child: inputDevices.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: Center(
                    child: Text(
                      'No microphone capture hardware endpoints detected',
                      style: TextStyle(
                        fontSize: 10,
                        color: StudioColors.textMuted,
                      ),
                    ),
                  ),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  itemCount: inputDevices.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, color: StudioColors.cardBorder),
                  itemBuilder: (context, index) {
                    final dev = inputDevices[index];
                    final isSelected = activeInputs.any(
                      (input) => input.deviceId == dev.id,
                    );

                    return Material(
                      color: Colors.transparent,
                      child: ListTile(
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 0,
                        ),
                        leading: Checkbox(
                          value: isSelected,
                          activeColor: StudioColors.accentAmber,
                          checkColor: Colors.black,
                          visualDensity: VisualDensity.compact,
                          onChanged: (_) => onToggleInput(dev),
                        ),
                        title: Text(
                          dev.displayName,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: isSelected
                                ? FontWeight.bold
                                : FontWeight.w500,
                            color: isSelected
                                ? Colors.white
                                : StudioColors.textSecondary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: isSelected
                            ? StreamBuilder<double>(
                                stream: micRmsStream,
                                initialData: initialMicRmsLevel,
                                builder: (context, rmsSnap) {
                                  final rms = rmsSnap.data ?? initialMicRmsLevel;
                                  return Text(
                                    'Active Capture • Level: ${rms.toStringAsFixed(1)} dBFS',
                                    style: const TextStyle(
                                      fontSize: 9,
                                      color: StudioColors.accentAmber,
                                      fontFamily: 'monospace',
                                    ),
                                  );
                                },
                              )
                            : (dev.isAuto
                                  ? Text(
                                      dev.resolvedName != null &&
                                              dev.resolvedName!.isNotEmpty
                                          ? 'Auto-routes to: ${dev.resolvedName}'
                                          : 'Auto-routes to default microphone',
                                      style: const TextStyle(
                                        fontSize: 9,
                                        color: StudioColors.accentAmber,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    )
                                  : Text(
                                      'Hardware ID: ${dev.id.substring(0, dev.id.length > 18 ? 18 : dev.id.length)}...',
                                      style: const TextStyle(
                                        fontSize: 9,
                                        color: StudioColors.textMuted,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    )),
                        trailing: IconButton(
                          icon: const Icon(Icons.settings, size: 16),
                          color: isSelected
                              ? StudioColors.accentCyan
                              : StudioColors.textMuted,
                          tooltip: 'Configure ${dev.displayName}',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => onConfigureInput(dev),
                        ),
                        onTap: () => onToggleInput(dev),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// No-op input toggle/configure callback safe for constant widget previews.
void _noopInputAction(AudioDevice _) {}

/// Preview rendering [InputCapturePanel] with active ducking and RMS telemetry.
@StudioPreview(
  name: 'Capture Input Matrix',
  group: 'Routing',
  size: Size(540, 210),
)
Widget inputCapturePanelPreview() {
  return InputCapturePanel(
    inputDevices: StudioPreviewData.sampleInputDevices,
    activeInputs: {const AudioInput(deviceId: 'AUTO')},
    isDuckingActive: true,
    initialMicRmsLevel: -22.4,
    onToggleInput: _noopInputAction,
    onConfigureInput: _noopInputAction,
  );
}
