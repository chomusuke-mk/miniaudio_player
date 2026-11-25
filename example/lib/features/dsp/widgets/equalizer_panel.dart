import 'package:material_ui/material_ui.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../../core/preview/studio_preview.dart';
import '../../../core/theme/studio_colors.dart';
import '../../../shared/painters/eq_curve_painter.dart';
import '../../../shared/widgets/dsp_sub_card.dart';

/// Pure presentational sub-card panel for the ISO 266 10-band parametric
/// equalizer, featuring preset selection and an interactive spline curve graph.
class EqualizerPanel extends StatelessWidget {
  /// ISO 266 center frequency labels aligned beneath each equalizer node.
  static const List<String> frequencyLabels = [
    '31',
    '63',
    '125',
    '250',
    '500',
    '1k',
    '2k',
    '4k',
    '8k',
    '16k',
  ];

  /// Ordered preset key-and-label entries exposed in the equalizer dropdown.
  static const List<({String key, String label})> presets = [
    (key: 'flat', label: 'Flat'),
    (key: 'rock', label: 'Rock'),
    (key: 'pop', label: 'Pop'),
    (key: 'jazz', label: 'Jazz'),
    (key: 'classical', label: 'Classical'),
    (key: 'bassBoost', label: 'Bass Boost'),
  ];

  /// Current 10-band equalizer state rendered by [EqCurvePainter].
  final Equalizer equalizer;

  /// Active preset identifier (one of [presets] keys or `'custom'`).
  final String selectedPreset;

  /// Invoked when the user toggles the equalizer power switch.
  final ValueChanged<bool> onToggle;

  /// Invoked when the user selects a preset key from [presets].
  final ValueChanged<String> onPresetChanged;

  /// Invoked when the user taps or drags on the response curve to adjust a band.
  final void Function(int bandIndex, double gainDb) onBandChanged;

  /// Creates an [EqualizerPanel] displaying [equalizer] and [selectedPreset] with
  /// [onToggle], [onPresetChanged], and [onBandChanged] callbacks.
  const EqualizerPanel({
    super.key,
    required this.equalizer,
    required this.selectedPreset,
    required this.onToggle,
    required this.onPresetChanged,
    required this.onBandChanged,
  });

  /// Maps pointer coordinates [localPos] within [size] to the nearest ISO band
  /// and decibel gain in `[-12.0, 12.0]`, then invokes [onBandChanged].
  void _handleGraphInteraction(Offset localPos, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    int closestBand = 0;
    double minDistance = double.infinity;
    for (int i = 0; i < EqCurvePainter.bandCount; i++) {
      final bandX = EqCurvePainter.getXForBand(i, size.width);
      final dist = (bandX - localPos.dx).abs();
      if (dist < minDistance) {
        minDistance = dist;
        closestBand = i;
      }
    }

    final centerY = size.height / 2;
    final verticalAmplitude = size.height * 0.38;
    final normalized = -((localPos.dy - centerY) / verticalAmplitude);
    final gainDb = (normalized * 12.0).clamp(-12.0, 12.0);

    onBandChanged(closestBand, gainDb);
  }

  /// Builds the labeled equalizer preset dropdown for [currentPreset].
  Widget _buildPresetDropdown(String currentPreset, bool enabled) {
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
        ...presets.map(
          (preset) => DropdownMenuItem(
            value: preset.key,
            child: Text(
              preset.label,
              style: const TextStyle(fontSize: 10.5),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        DropdownMenuItem(
          value: 'custom',
          enabled: currentPreset == 'custom',
          child: Text(
            'Custom',
            style: TextStyle(
              fontSize: 10.5,
              fontStyle: FontStyle.italic,
              color: currentPreset == 'custom'
                  ? StudioColors.accentCyan
                  : StudioColors.textMuted,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
      onChanged: enabled
          ? (presetKey) {
              if (presetKey == null || presetKey == 'custom') return;
              onPresetChanged(presetKey);
            }
          : null,
    );
  }

  /// Builds the 10-band equalizer curve panel inside [DspSubCard].
  @override
  Widget build(BuildContext context) {
    final isEnabled = equalizer.enabled;
    final currentPreset = presets.any((preset) => preset.key == selectedPreset)
        ? selectedPreset
        : 'custom';
    final activePresetLabel =
        presets
            .where((preset) => preset.key == currentPreset)
            .map((preset) => preset.label)
            .firstOrNull ??
        'Custom';
    final bandsList = equalizer.toList();

    return DspSubCard(
      icon: Icons.tune,
      title: 'ISO 266 10-Band Equalizer',
      subtitle: isEnabled
          ? 'Active: $activePresetLabel • Direct Form II Transposed'
          : 'Inactive: DF2T SIMD 10-band parametric response',
      enabled: isEnabled,
      accentColor: StudioColors.accentCyan,
      onToggle: onToggle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildPresetDropdown(currentPreset, isEnabled),
          const SizedBox(height: 10),
          Builder(
            builder: (graphContext) {
              const graphHeight = 130.0;
              void handleInteraction(Offset localPosition) {
                final box = graphContext.findRenderObject() as RenderBox?;
                if (box == null || !box.hasSize) return;
                _handleGraphInteraction(
                  localPosition,
                  Size(box.size.width, graphHeight),
                );
              }

              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) =>
                    handleInteraction(details.localPosition),
                onPanUpdate: (details) =>
                    handleInteraction(details.localPosition),
                child: Container(
                  height: graphHeight,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: StudioColors.cardBorder,
                      width: 1.0,
                    ),
                  ),
                  child: CustomPaint(
                    painter: EqCurvePainter(
                      equalizer: equalizer,
                      activeColor: StudioColors.accentCyan,
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Expanded(flex: 1, child: SizedBox.shrink()),
              for (int i = 0; i < EqCurvePainter.bandCount; i++) ...[
                Expanded(
                  flex: 2,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        frequencyLabels[i],
                        style: const TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          fontFamily: 'monospace',
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        bandsList[i] > 0
                            ? '+${bandsList[i].toStringAsFixed(1)}'
                            : bandsList[i].toStringAsFixed(1),
                        style: TextStyle(
                          fontSize: 8,
                          fontWeight: FontWeight.w700,
                          color: bandsList[i] != 0.0
                              ? StudioColors.accentCyan
                              : StudioColors.textMuted,
                          fontFamily: 'monospace',
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
              const Expanded(flex: 1, child: SizedBox.shrink()),
            ],
          ),
        ],
      ),
    );
  }
}

/// No-op preset callback safe for constant widget previews.
void _noopEqPreset(String _) {}

/// No-op equalizer band callback safe for constant widget previews.
void _noopEqBand(int _, double _) {}

/// Preview rendering [EqualizerPanel] with the built-in Rock curve enabled.
@StudioPreview(
  name: '10-Band Equalizer',
  group: 'DSP',
  size: Size(620, 340),
)
Widget equalizerPanelPreview() {
  return EqualizerPanel(
    equalizer: Equalizer.rock.copyWith(enabled: true),
    selectedPreset: 'rock',
    onToggle: StudioPreviewData.noopBool,
    onPresetChanged: _noopEqPreset,
    onBandChanged: _noopEqBand,
  );
}
