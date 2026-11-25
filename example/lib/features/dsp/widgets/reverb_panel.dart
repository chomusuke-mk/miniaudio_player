import 'package:material_ui/material_ui.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../../core/preview/studio_preview.dart';
import '../../../core/theme/studio_colors.dart';
import '../../../shared/widgets/compact_slider_overlay.dart';
import '../../../shared/widgets/dsp_sub_card.dart';

/// Pure presentational sub-card panel for Freeverb algorithmic reverberation,
/// exposing preset selection and room size, damping, width, wet, and dry pills.
class ReverbPanel extends StatelessWidget {
  /// Ordered list of built-in reverb preset names shown in the selector.
  static const List<String> reverbPresets = [
    'Small Room',
    'Studio',
    'Concert Hall',
    'Cathedral',
    'Plate',
    'Ambient',
  ];

  /// Whether algorithmic reverberation is active.
  final bool enabled;

  /// Active preset label or `'Custom'` when parameters diverge from presets.
  final String selectedPreset;

  /// Normalized Freeverb room size parameter (`0.0` to `1.0`).
  final double roomSize;

  /// Normalized high-frequency damping factor (`0.0` to `1.0`).
  final double damping;

  /// Normalized stereo reverb spread (`0.0` to `1.0`).
  final double width;

  /// Wet reverberation mix gain multiplier (`0.0` to `2.0`).
  final double wet;

  /// Dry direct-signal mix gain multiplier (`0.0` to `2.0`).
  final double dry;

  /// Invoked when the user toggles the reverb power switch.
  final ValueChanged<bool> onToggle;

  /// Invoked when the user selects a named preset from [reverbPresets].
  final ValueChanged<String> onPresetChanged;

  /// Invoked when the user adjusts [roomSize].
  final ValueChanged<double> onRoomSizeChanged;

  /// Invoked when the user adjusts [damping].
  final ValueChanged<double> onDampingChanged;

  /// Invoked when the user adjusts [width].
  final ValueChanged<double> onWidthChanged;

  /// Invoked when the user adjusts [wet] level.
  final ValueChanged<double> onWetChanged;

  /// Invoked when the user adjusts [dry] level.
  final ValueChanged<double> onDryChanged;

  /// Creates a [ReverbPanel] displaying [enabled], [selectedPreset], [roomSize],
  /// [damping], [width], [wet], and [dry] with [onToggle], [onPresetChanged],
  /// [onRoomSizeChanged], [onDampingChanged], [onWidthChanged], [onWetChanged],
  /// and [onDryChanged] callbacks.
  const ReverbPanel({
    super.key,
    required this.enabled,
    required this.selectedPreset,
    required this.roomSize,
    required this.damping,
    required this.width,
    required this.wet,
    required this.dry,
    required this.onToggle,
    required this.onPresetChanged,
    required this.onRoomSizeChanged,
    required this.onDampingChanged,
    required this.onWidthChanged,
    required this.onWetChanged,
    required this.onDryChanged,
  });

  /// Builds the labeled reverb preset dropdown for [currentPreset] when [enabled].
  Widget _buildPresetDropdown(String currentPreset) {
    return DropdownButtonFormField<String>(
      key: ValueKey(currentPreset),
      initialValue: currentPreset,
      isExpanded: true,
      dropdownColor: const Color(0xFF0E1424),
      decoration: const InputDecoration(
        labelText: 'Preset',
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      ),
      items: [
        ...reverbPresets.map(
          (preset) => DropdownMenuItem(
            value: preset,
            child: Text(
              preset,
              style: const TextStyle(fontSize: 10.5),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        DropdownMenuItem(
          value: 'Custom',
          enabled: currentPreset == 'Custom',
          child: Text(
            'Custom',
            style: TextStyle(
              fontSize: 10.5,
              fontStyle: FontStyle.italic,
              color: currentPreset == 'Custom'
                  ? StudioColors.accentViolet
                  : StudioColors.textMuted,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
      onChanged: enabled
          ? (preset) {
              if (preset == null || preset == 'Custom') return;
              onPresetChanged(preset);
            }
          : null,
    );
  }

  /// Builds the algorithmic reverb module inside [DspSubCard].
  @override
  Widget build(BuildContext context) {
    final currentPreset = reverbPresets.contains(selectedPreset)
        ? selectedPreset
        : 'Custom';

    return DspSubCard(
      icon: Icons.account_balance,
      title: 'Algorithmic Reverb',
      subtitle: enabled
          ? 'Active: $currentPreset • Wet ${wet.toStringAsFixed(2)}x'
          : 'Freeverb 8-comb acoustic space simulation',
      enabled: enabled,
      accentColor: StudioColors.accentViolet,
      onToggle: onToggle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildPresetDropdown(currentPreset),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.start,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 6,
            runSpacing: 6,
            children: [
              CompactSliderControl(
                icon: Icons.open_in_full,
                label: 'Room Size: ${roomSize.toStringAsFixed(2)}',
                valueFormatter: (value) => value.toStringAsFixed(2),
                value: roomSize.clamp(0.0, 1.0),
                defaultValue: Reverb.studio.roomSize,
                min: 0.0,
                max: 1.0,
                activeColor: StudioColors.accentCyan,
                disabled: !enabled,
                onChanged: onRoomSizeChanged,
              ),
              CompactSliderControl(
                icon: Icons.blur_on,
                label: 'Damping: ${damping.toStringAsFixed(2)}',
                valueFormatter: (value) => value.toStringAsFixed(2),
                value: damping.clamp(0.0, 1.0),
                defaultValue: Reverb.studio.damping,
                min: 0.0,
                max: 1.0,
                activeColor: StudioColors.accentViolet,
                disabled: !enabled,
                onChanged: onDampingChanged,
              ),
              CompactSliderControl(
                icon: Icons.swap_horiz,
                label: 'Width: ${width.toStringAsFixed(2)}',
                valueFormatter: (value) => value.toStringAsFixed(2),
                value: width.clamp(0.0, 1.0),
                defaultValue: Reverb.studio.width,
                min: 0.0,
                max: 1.0,
                activeColor: StudioColors.accentEmerald,
                disabled: !enabled,
                onChanged: onWidthChanged,
              ),
              CompactSliderControl(
                icon: Icons.water_drop,
                label: 'Wet Level: ${wet.toStringAsFixed(2)}x',
                valueFormatter: (value) => '${value.toStringAsFixed(2)}x',
                value: wet.clamp(0.0, 2.0),
                defaultValue: Reverb.studio.wet,
                min: 0.0,
                max: 2.0,
                activeColor: StudioColors.accentAmber,
                disabled: !enabled,
                onChanged: onWetChanged,
              ),
              CompactSliderControl(
                icon: Icons.waves,
                label: 'Dry Level: ${dry.toStringAsFixed(2)}x',
                valueFormatter: (value) => '${value.toStringAsFixed(2)}x',
                value: dry.clamp(0.0, 2.0),
                defaultValue: Reverb.studio.dry,
                min: 0.0,
                max: 2.0,
                activeColor: const Color(0xFFFF5252),
                disabled: !enabled,
                onChanged: onDryChanged,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// No-op preset callback safe for constant widget previews.
void _noopReverbPreset(String _) {}

/// Preview rendering [ReverbPanel] with the Studio reverb preset active.
@StudioPreview(
  name: 'Algorithmic Reverb',
  group: 'DSP',
  size: Size(340, 280),
)
Widget reverbPanelPreview() {
  return ReverbPanel(
    enabled: true,
    selectedPreset: 'Studio',
    roomSize: Reverb.studio.roomSize,
    damping: Reverb.studio.damping,
    width: Reverb.studio.width,
    wet: Reverb.studio.wet,
    dry: Reverb.studio.dry,
    onToggle: StudioPreviewData.noopBool,
    onPresetChanged: _noopReverbPreset,
    onRoomSizeChanged: StudioPreviewData.noopDouble,
    onDampingChanged: StudioPreviewData.noopDouble,
    onWidthChanged: StudioPreviewData.noopDouble,
    onWetChanged: StudioPreviewData.noopDouble,
    onDryChanged: StudioPreviewData.noopDouble,
  );
}
