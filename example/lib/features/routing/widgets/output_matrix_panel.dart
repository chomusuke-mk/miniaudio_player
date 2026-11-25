import 'package:material_ui/material_ui.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../../core/preview/studio_preview.dart';
import '../../../core/theme/studio_colors.dart';

/// Pure presentational matrix listing playback output endpoints, active
/// selection toggles, and per-device stream bus routing dropdowns.
class OutputMatrixPanel extends StatelessWidget {
  /// Discovered global hardware playback devices.
  final List<AudioDevice> outputDevices;

  /// Currently active output endpoints and their assigned [AudioOutputSource].
  final Set<AudioOutput> activeOutputs;

  /// Invoked when the user toggles activation for a playback [device].
  final ValueChanged<AudioDevice> onToggleOutput;

  /// Invoked when the user assigns a routing [source] for a specific device
  /// identified by `deviceId`.
  final void Function(String deviceId, AudioOutputSource source)
  onOutputSourceChanged;

  /// Creates an [OutputMatrixPanel] rendering [outputDevices] against
  /// [activeOutputs] with [onToggleOutput] and [onOutputSourceChanged] actions.
  const OutputMatrixPanel({
    super.key,
    required this.outputDevices,
    required this.activeOutputs,
    required this.onToggleOutput,
    required this.onOutputSourceChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Row(
          children: [
            Icon(Icons.headphones, size: 14, color: StudioColors.accentCyan),
            SizedBox(width: 6),
            Expanded(
              child: Text(
                'PLAYBACK OUTPUT DESTINATIONS (MULTI-SELECT)',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: StudioColors.accentCyan,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFF070B14),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: StudioColors.cardBorder),
          ),
          child: outputDevices.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: Center(
                    child: Text(
                      'No playback destination hardware endpoints detected',
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
                  itemCount: outputDevices.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, color: StudioColors.cardBorder),
                  itemBuilder: (context, index) {
                    final dev = outputDevices[index];
                    final isSelected = activeOutputs.any(
                      (output) => output.deviceId == dev.id,
                    );
                    final matchingOutput = isSelected
                        ? activeOutputs.firstWhere(
                            (output) => output.deviceId == dev.id,
                          )
                        : null;

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
                          activeColor: StudioColors.accentCyan,
                          checkColor: Colors.black,
                          visualDensity: VisualDensity.compact,
                          onChanged: (_) => onToggleOutput(dev),
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
                        subtitle: dev.isAuto
                            ? Text(
                                dev.resolvedName != null &&
                                        dev.resolvedName!.isNotEmpty
                                    ? 'Auto-routes to: ${dev.resolvedName}'
                                    : 'Auto-routes to active OS default audio endpoint',
                                style: const TextStyle(
                                  fontSize: 9,
                                  color: StudioColors.accentCyan,
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
                              ),
                        trailing: isSelected
                            ? SizedBox(
                                width: 96,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF0F172A),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(
                                      color: StudioColors.cardBorder,
                                    ),
                                  ),
                                  child: DropdownButtonHideUnderline(
                                    child: DropdownButton<AudioOutputSource>(
                                      value:
                                          matchingOutput?.source ??
                                          AudioOutputSource.all,
                                      icon: const Icon(
                                        Icons.arrow_drop_down,
                                        size: 14,
                                      ),
                                      dropdownColor: const Color(0xFF0F172A),
                                      isExpanded: true,
                                      isDense: true,
                                      items: const [
                                        DropdownMenuItem(
                                          value: AudioOutputSource.all,
                                          child: Text(
                                            'All Mix',
                                            style: TextStyle(fontSize: 9.5),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        DropdownMenuItem(
                                          value: AudioOutputSource.musicMix,
                                          child: Text(
                                            'Music Only',
                                            style: TextStyle(fontSize: 9.5),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        DropdownMenuItem(
                                          value: AudioOutputSource.activeTrack,
                                          child: Text(
                                            'Active Deck',
                                            style: TextStyle(fontSize: 9.5),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        DropdownMenuItem(
                                          value: AudioOutputSource.standbyTrack,
                                          child: Text(
                                            'Cue Deck',
                                            style: TextStyle(fontSize: 9.5),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        DropdownMenuItem(
                                          value: AudioOutputSource.voiceOnly,
                                          child: Text(
                                            'Voice Only',
                                            style: TextStyle(fontSize: 9.5),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                      onChanged: (source) {
                                        if (source != null) {
                                          onOutputSourceChanged(dev.id, source);
                                        }
                                      },
                                    ),
                                  ),
                                ),
                              )
                            : null,
                        onTap: () => onToggleOutput(dev),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// No-op output toggle callback safe for constant widget previews.
void _noopToggleOutput(AudioDevice _) {}

/// No-op output source routing callback safe for constant widget previews.
void _noopOutputSource(String _, AudioOutputSource _) {}

/// Preview rendering [OutputMatrixPanel] with active multi-destination routing.
@StudioPreview(
  name: 'Output Routing Matrix',
  group: 'Routing',
  size: Size(540, 250),
)
Widget outputMatrixPanelPreview() {
  return OutputMatrixPanel(
    outputDevices: StudioPreviewData.sampleOutputDevices,
    activeOutputs: {
      const AudioOutput(deviceId: 'AUTO', source: AudioOutputSource.all),
      const AudioOutput(
        deviceId: 'hw_cue_phones',
        source: AudioOutputSource.standbyTrack,
      ),
    },
    onToggleOutput: _noopToggleOutput,
    onOutputSourceChanged: _noopOutputSource,
  );
}
