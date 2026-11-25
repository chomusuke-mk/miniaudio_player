import 'package:material_ui/material_ui.dart';

import '../../../core/preview/studio_preview.dart';
import '../../../core/theme/studio_colors.dart';
import '../../../shared/widgets/compact_slider_overlay.dart';
import '../../../shared/widgets/dsp_sub_card.dart';

/// Pure presentational sub-card panel for the Mid/Side stereo widener DSP
/// stage, providing a power switch and stereo width multiplier pill.
class StereoWidenerPanel extends StatelessWidget {
  /// Whether the stereo widener processor is enabled.
  final bool enabled;

  /// Stereo width multiplier (`0.0` mono through `2.0` ultra-wide).
  final double width;

  /// Invoked when the user toggles the module power switch.
  final ValueChanged<bool> onToggle;

  /// Invoked when the user adjusts the stereo width multiplier.
  final ValueChanged<double> onWidthChanged;

  /// Creates a [StereoWidenerPanel] displaying [enabled] and [width] with
  /// [onToggle] and [onWidthChanged] callbacks.
  const StereoWidenerPanel({
    super.key,
    required this.enabled,
    required this.width,
    required this.onToggle,
    required this.onWidthChanged,
  });

  /// Builds the stereo widener module inside [DspSubCard].
  @override
  Widget build(BuildContext context) {
    return DspSubCard(
      icon: Icons.surround_sound,
      title: 'Stereo Widener',
      subtitle: enabled
          ? 'Active: ${width.toStringAsFixed(2)}x Mid/Side spatializer'
          : 'Inactive: standard Mid/Side spatializer field',
      enabled: enabled,
      accentColor: StudioColors.accentCyan,
      onToggle: onToggle,
      child: Wrap(
        alignment: WrapAlignment.start,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        runSpacing: 6,
        children: [
          CompactSliderControl(
            icon: Icons.swap_horiz,
            label: 'Width: ${width.toStringAsFixed(2)}x',
            value: width.clamp(0.0, 2.0),
            defaultValue: 1.0,
            min: 0.0,
            max: 2.0,
            activeColor: StudioColors.accentCyan,
            disabled: !enabled,
            valueFormatter: (value) => '${value.toStringAsFixed(2)}x',
            onChanged: onWidthChanged,
          ),
        ],
      ),
    );
  }
}

/// Preview rendering [StereoWidenerPanel] in an active `1.35x` width state.
@StudioPreview(
  name: 'Stereo Widener',
  group: 'DSP',
  size: Size(320, 170),
)
Widget stereoWidenerPanelPreview() {
  return const StereoWidenerPanel(
    enabled: true,
    width: 1.35,
    onToggle: StudioPreviewData.noopBool,
    onWidthChanged: StudioPreviewData.noopDouble,
  );
}
