import 'package:material_ui/material_ui.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../../core/preview/studio_preview.dart';
import '../../../core/theme/studio_colors.dart';

/// Pure presentational live recording dock below transport controls supporting
/// record/stop actions, format/source selectors, Web OPFS targeting, and
/// open/download/play/delete actions for the latest take.
class LiveRecordingPanel extends StatelessWidget {
  /// Whether live audio recording is currently active.
  final bool isRecording;

  /// Elapsed duration of the active take.
  final Duration recordedDuration;

  /// Whether Web-specific controls (`Use OPFS`, browser download) should render.
  final bool isWebUi;

  /// Whether Web captures write to OPFS instead of volatile RAM buffers.
  final bool useWebOpfs;

  /// Selected target container format for the next capture.
  final AudioFileFormat recordingFormat;

  /// Selected engine tap source captured into the recording.
  final AudioOutputSource recordingSource;

  /// Metadata and path summary of the latest finished capture, if any.
  final RecordingResult? lastRecordingResult;

  /// Short base filename shown on the last recording pill, if any.
  final String? lastRecordingFileName;

  /// Invoked when the user toggles recording start or stop.
  final VoidCallback onToggleRecord;

  /// Invoked when the user changes [recordingFormat].
  final ValueChanged<AudioFileFormat> onFormatChanged;

  /// Invoked when the user changes [recordingSource].
  final ValueChanged<AudioOutputSource> onSourceChanged;

  /// Invoked when the user toggles Web OPFS capture storage.
  final ValueChanged<bool> onUseWebOpfsChanged;

  /// Invoked when the user clicks the last-recording pill to open it.
  final VoidCallback onOpenLastRecording;

  /// Invoked on Web when the user downloads the completed take.
  final VoidCallback onDownloadLastRecording;

  /// Invoked when the user plays back the completed take in the engine.
  final VoidCallback onPlayLastRecording;

  /// Invoked when the user deletes the completed take.
  final VoidCallback onDeleteLastRecording;

  /// Creates a [LiveRecordingPanel] exposing live capture status and controls
  /// for [isRecording], [recordedDuration], [isWebUi], [useWebOpfs],
  /// [recordingFormat], [recordingSource], [lastRecordingResult], and
  /// [lastRecordingFileName].
  const LiveRecordingPanel({
    super.key,
    required this.isRecording,
    required this.recordedDuration,
    required this.isWebUi,
    required this.useWebOpfs,
    required this.recordingFormat,
    required this.recordingSource,
    required this.lastRecordingResult,
    required this.lastRecordingFileName,
    required this.onToggleRecord,
    required this.onFormatChanged,
    required this.onSourceChanged,
    required this.onUseWebOpfsChanged,
    required this.onOpenLastRecording,
    required this.onDownloadLastRecording,
    required this.onPlayLastRecording,
    required this.onDeleteLastRecording,
  });

  /// Formats [d] as `MM:SS.t` for elapsed timer and completed take badges.
  static String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final tenths = (d.inMilliseconds.remainder(1000) ~/ 100).toString();
    return '$minutes:$seconds.$tenths';
  }

  @override
  Widget build(BuildContext context) {
    final isRec = isRecording;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0C101C),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isRec ? StudioColors.accentRose : StudioColors.cardBorder,
          width: isRec ? 1.4 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.fiber_manual_record,
                size: 14,
                color: isRec ? StudioColors.accentRose : StudioColors.textMuted,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  isRec
                      ? 'RECORDING IN PROGRESS'
                      : (isWebUi
                            ? (useWebOpfs
                                  ? 'LIVE OPFS RECORDER'
                                  : 'LIVE MEMORY RECORDER')
                            : 'LIVE DISK RECORDER'),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                    color: isRec
                        ? StudioColors.accentRose
                        : StudioColors.accentCyan,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (isRec) ...[
                const SizedBox(width: 4),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: StudioColors.accentRose.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: StudioColors.accentRose,
                      width: 0.8,
                    ),
                  ),
                  child: Text(
                    _formatDuration(recordedDuration),
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'monospace',
                      color: StudioColors.accentRose,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: isRec
                      ? StudioColors.accentRose
                      : const Color(0xFF1E283E),
                  foregroundColor: isRec
                      ? Colors.white
                      : StudioColors.accentRose,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                    side: BorderSide(
                      color: isRec
                          ? StudioColors.accentRose
                          : StudioColors.cardBorder,
                    ),
                  ),
                ),
                icon: Icon(
                  isRec ? Icons.stop : Icons.fiber_manual_record,
                  size: 16,
                  color: isRec ? Colors.white : StudioColors.accentRose,
                ),
                label: Text(
                  isRec ? 'STOP' : 'RECORD',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                onPressed: onToggleRecord,
              ),
              if (!isRec)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF070B14),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: StudioColors.cardBorder),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<AudioFileFormat>(
                      value: recordingFormat,
                      isDense: true,
                      icon: const Icon(Icons.arrow_drop_down, size: 16),
                      dropdownColor: const Color(0xFF0E172A),
                      selectedItemBuilder: (context) => AudioFileFormat
                          .supportedRecordingFormats
                          .map((format) {
                            return Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                format.shortLabel,
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            );
                          })
                          .toList(),
                      items: AudioFileFormat.supportedRecordingFormats.map((
                        format,
                      ) {
                        return DropdownMenuItem(
                          value: format,
                          child: Text(
                            format.displayLabel,
                            style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        );
                      }).toList(),
                      onChanged: (format) {
                        if (format != null) onFormatChanged(format);
                      },
                    ),
                  ),
                ),
              if (!isRec)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF070B14),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: StudioColors.cardBorder),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<AudioOutputSource>(
                      value: recordingSource,
                      isDense: true,
                      icon: const Icon(Icons.arrow_drop_down, size: 16),
                      dropdownColor: const Color(0xFF0E172A),
                      items: const [
                        DropdownMenuItem(
                          value: AudioOutputSource.all,
                          child: Text(
                            'All Mix',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        DropdownMenuItem(
                          value: AudioOutputSource.musicMix,
                          child: Text(
                            'Music',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        DropdownMenuItem(
                          value: AudioOutputSource.activeTrack,
                          child: Text(
                            'Active',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        DropdownMenuItem(
                          value: AudioOutputSource.standbyTrack,
                          child: Text(
                            'Cue',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        DropdownMenuItem(
                          value: AudioOutputSource.voiceOnly,
                          child: Text(
                            'Voice Only',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                      onChanged: (source) {
                        if (source != null) onSourceChanged(source);
                      },
                    ),
                  ),
                ),
              if (isWebUi && !isRec)
                Tooltip(
                  message:
                      'Most recommended for large files, though not available in all browsers.',
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => onUseWebOpfsChanged(!useWebOpfs),
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        padding: const EdgeInsets.only(
                          left: 4,
                          right: 8,
                          top: 3,
                          bottom: 3,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF070B14),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: useWebOpfs
                                ? StudioColors.accentCyan
                                : StudioColors.cardBorder,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 18,
                              height: 18,
                              child: Checkbox(
                                value: useWebOpfs,
                                onChanged: (checked) =>
                                    onUseWebOpfsChanged(checked ?? false),
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                visualDensity: VisualDensity.compact,
                                activeColor: StudioColors.accentCyan,
                                checkColor: const Color(0xFF070B14),
                                side: const BorderSide(
                                  color: StudioColors.textMuted,
                                  width: 1.4,
                                ),
                              ),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              'Use OPFS',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: useWebOpfs
                                    ? StudioColors.accentCyan
                                    : StudioColors.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (lastRecordingResult != null && !isRec)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 280),
                  child: Tooltip(
                    message: 'Open last recording',
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: onOpenLastRecording,
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF070B14),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: StudioColors.accentCyan.withValues(
                                alpha: 0.45,
                              ),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.open_in_new,
                                size: 12,
                                color: StudioColors.accentCyan,
                              ),
                              const SizedBox(width: 5),
                              Flexible(
                                child: Text(
                                  'Last: ${lastRecordingFileName ?? ''} (${_formatDuration(lastRecordingResult!.duration)})',
                                  style: const TextStyle(
                                    fontSize: 9.5,
                                    color: StudioColors.accentCyan,
                                    fontFamily: 'monospace',
                                    decoration: TextDecoration.underline,
                                    decorationColor: StudioColors.accentCyan,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (lastRecordingResult != null && !isRec && isWebUi)
                Tooltip(
                  message: 'Download ${lastRecordingFileName ?? "recording"}',
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: onDownloadLastRecording,
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF070B14),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: StudioColors.accentEmerald.withValues(
                              alpha: 0.45,
                            ),
                          ),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.download,
                              size: 12,
                              color: StudioColors.accentEmerald,
                            ),
                            SizedBox(width: 4),
                            Text(
                              'Download',
                              style: TextStyle(
                                fontSize: 9.5,
                                color: StudioColors.accentEmerald,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (lastRecordingResult != null && !isRec)
                Tooltip(
                  message: 'Play last recording',
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: onPlayLastRecording,
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF070B14),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: StudioColors.accentCyan.withValues(
                              alpha: 0.45,
                            ),
                          ),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.play_arrow,
                              size: 12,
                              color: StudioColors.accentCyan,
                            ),
                            SizedBox(width: 3),
                            Text(
                              'Play',
                              style: TextStyle(
                                fontSize: 9.5,
                                color: StudioColors.accentCyan,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (lastRecordingResult != null && !isRec)
                Tooltip(
                  message: 'Delete last recording',
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: onDeleteLastRecording,
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF070B14),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: StudioColors.accentRose.withValues(
                              alpha: 0.45,
                            ),
                          ),
                        ),
                        child: const Icon(
                          Icons.delete_outline,
                          size: 13,
                          color: StudioColors.accentRose,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// No-op recording format callback safe for constant widget previews.
void _noopRecordingFormat(AudioFileFormat _) {}

/// No-op recording source callback safe for constant widget previews.
void _noopRecordingSource(AudioOutputSource _) {}

/// Preview rendering [LiveRecordingPanel] in idle Web OPFS ready mode.
@StudioPreview(
  name: 'Live Recording Panel',
  group: 'Playback',
  size: Size(560, 120),
)
Widget liveRecordingPanelPreview() {
  return const LiveRecordingPanel(
    isRecording: false,
    recordedDuration: Duration(seconds: 18, milliseconds: 400),
    isWebUi: true,
    useWebOpfs: true,
    recordingFormat: AudioFileFormat.wav,
    recordingSource: AudioOutputSource.all,
    lastRecordingResult: null,
    lastRecordingFileName: null,
    onToggleRecord: StudioPreviewData.noopVoid,
    onFormatChanged: _noopRecordingFormat,
    onSourceChanged: _noopRecordingSource,
    onUseWebOpfsChanged: StudioPreviewData.noopBool,
    onOpenLastRecording: StudioPreviewData.noopVoid,
    onDownloadLastRecording: StudioPreviewData.noopVoid,
    onPlayLastRecording: StudioPreviewData.noopVoid,
    onDeleteLastRecording: StudioPreviewData.noopVoid,
  );
}
