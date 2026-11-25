import 'package:material_ui/material_ui.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../../core/preview/studio_preview.dart';
import '../../../core/theme/studio_colors.dart';
import '../../../shared/widgets/compact_slider_overlay.dart';
import '../../../shared/widgets/dsp_sub_card.dart';

/// Pure presentational sub-card panel for intelligent silence skipping,
/// exposing toggle, [SilenceSkipMode] selector, and threshold dB control.
class SilenceSkipPanel extends StatelessWidget {
  /// Whether silence skipping is currently active.
  final bool enabled;

  /// Active silence detection mode.
  final SilenceSkipMode mode;

  /// RMS amplitude threshold in decibels below which audio counts as silence.
  final double thresholdDb;

  /// Cumulative playback time saved by skipping silent passages.
  final Duration savedDuration;

  /// Invoked when the user toggles the module power switch.
  final ValueChanged<bool> onToggle;

  /// Invoked when the user selects a new [SilenceSkipMode].
  final ValueChanged<SilenceSkipMode> onModeChanged;

  /// Invoked when the user adjusts the silence detection threshold in dB.
  final ValueChanged<double> onThresholdChanged;

  /// Creates a [SilenceSkipPanel] displaying [enabled], [mode], [thresholdDb],
  /// and [savedDuration] with [onToggle], [onModeChanged], and
  /// [onThresholdChanged] callbacks.
  const SilenceSkipPanel({
    super.key,
    required this.enabled,
    required this.mode,
    required this.thresholdDb,
    required this.savedDuration,
    required this.onToggle,
    required this.onModeChanged,
    required this.onThresholdChanged,
  });

  /// Formats [duration] as seconds with tenth-second precision (e.g. `4.2s`).
  static String _formatDuration(Duration duration) {
    final seconds = duration.inSeconds;
    final tenths = duration.inMilliseconds.remainder(1000) ~/ 100;
    return '$seconds.$tenths' 's';
  }

  /// Resolves an active dropdown [SilenceSkipMode], falling back to
  /// [SilenceSkipMode.all] if [SilenceSkipMode.disabled] is supplied.
  SilenceSkipMode get _effectiveMode =>
      mode == SilenceSkipMode.disabled ? SilenceSkipMode.all : mode;

  /// Builds the silence skip panel layout inside [DspSubCard].
  @override
  Widget build(BuildContext context) {
    final activeMode = _effectiveMode;

    return DspSubCard(
      icon: Icons.hourglass_empty,
      title: 'Smart Silence Skipping',
      subtitle: enabled
          ? 'Skipped: ${_formatDuration(savedDuration)} saved'
          : 'Inactive: plays full timeline without skipping',
      enabled: enabled,
      accentColor: StudioColors.accentPurple,
      onToggle: onToggle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<SilenceSkipMode>(
            key: ValueKey(activeMode),
            initialValue: activeMode,
            isExpanded: true,
            dropdownColor: const Color(0xFF0E1424),
            decoration: const InputDecoration(
              labelText: 'Silence Skip Mode',
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            ),
            items: const [
              DropdownMenuItem(
                value: SilenceSkipMode.all,
                child: Text(
                  'All (Edges + In-Between Pauses)',
                  style: TextStyle(fontSize: 10),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              DropdownMenuItem(
                value: SilenceSkipMode.trimEdges,
                child: Text(
                  'Trim Edges (Intro & Outro)',
                  style: TextStyle(fontSize: 10),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              DropdownMenuItem(
                value: SilenceSkipMode.continuous,
                child: Text(
                  'Continuous Pauses (Middle Only)',
                  style: TextStyle(fontSize: 10),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            onChanged: enabled
                ? (selectedMode) {
                    if (selectedMode != null) {
                      onModeChanged(selectedMode);
                    }
                  }
                : null,
          ),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.start,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 6,
            runSpacing: 6,
            children: [
              CompactSliderControl(
                icon: Icons.graphic_eq,
                label: 'Threshold: ${thresholdDb.toStringAsFixed(1)} dB',
                value: thresholdDb.clamp(-90.0, -20.0),
                defaultValue: -45.0,
                min: -90.0,
                max: -20.0,
                activeColor: StudioColors.accentPurple,
                disabled: !enabled,
                valueFormatter: (value) => '${value.toStringAsFixed(1)} dB',
                onChanged: onThresholdChanged,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// No-op [SilenceSkipMode] callback safe for constant widget previews.
void _noopSilenceMode(SilenceSkipMode _) {}

/// Preview rendering [SilenceSkipPanel] in an active state with sample savings.
@StudioPreview(
  name: 'Smart Silence Skipping',
  group: 'DSP',
  size: Size(320, 230),
)
Widget silenceSkipPanelPreview() {
  return const SilenceSkipPanel(
    enabled: true,
    mode: SilenceSkipMode.all,
    thresholdDb: -45.0,
    savedDuration: Duration(seconds: 4, milliseconds: 200),
    onToggle: StudioPreviewData.noopBool,
    onModeChanged: _noopSilenceMode,
    onThresholdChanged: StudioPreviewData.noopDouble,
  );
}
