import 'package:flutter/material.dart';
import '../../theme/studio_colors.dart';

/// Floating modal dialog for continuous parameter adjustments (Speed, Pitch, Crossfade).
class FloatingSliderDialog extends StatefulWidget {
  final String title;
  final String subtitle;
  final double initialValue;
  final double min;
  final double max;
  final String unit;
  final int decimals;
  final List<({String label, double value})> presets;
  final ValueChanged<double> onChanged;

  const FloatingSliderDialog({
    super.key,
    required this.title,
    this.subtitle = 'DSP Precision Parameter Adjustment',
    required this.initialValue,
    required this.min,
    required this.max,
    required this.unit,
    this.decimals = 2,
    this.presets = const [],
    required this.onChanged,
  });

  static Future<void> show({
    required BuildContext context,
    required String title,
    String subtitle = 'DSP Precision Parameter Adjustment',
    required double initialValue,
    required double min,
    required double max,
    required String unit,
    int decimals = 2,
    List<({String label, double value})> presets = const [],
    required ValueChanged<double> onChanged,
  }) {
    return showDialog(
      context: context,
      builder: (ctx) => FloatingSliderDialog(
        title: title,
        subtitle: subtitle,
        initialValue: initialValue,
        min: min,
        max: max,
        unit: unit,
        decimals: decimals,
        presets: presets,
        onChanged: onChanged,
      ),
    );
  }

  @override
  State<FloatingSliderDialog> createState() => _FloatingSliderDialogState();
}

class _FloatingSliderDialogState extends State<FloatingSliderDialog> {
  late double _currentVal;

  @override
  void initState() {
    super.initState();
    _currentVal = widget.initialValue;
  }

  @override
  Widget build(BuildContext context) {
    final valueText = '${_currentVal.toStringAsFixed(widget.decimals)}${widget.unit}';

    return Dialog(
      backgroundColor: StudioColors.cardBackground,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: StudioColors.cardBorderFocused, width: 1.5),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                            color: StudioColors.accentCyan,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          widget.subtitle,
                          style: const TextStyle(
                            fontSize: 9,
                            color: StudioColors.textSecondary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    color: StudioColors.textMuted,
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // Big readout value
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  decoration: BoxDecoration(
                    color: StudioColors.backgroundDark,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: StudioColors.cardBorder),
                  ),
                  child: Text(
                    valueText,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w900,
                      color: StudioColors.accentCyan,
                      letterSpacing: 1.0,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // Slider
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4,
                  activeTrackColor: StudioColors.accentCyan,
                  inactiveTrackColor: StudioColors.cardBorderFocused,
                  thumbColor: StudioColors.accentCyan,
                  overlayColor: StudioColors.accentCyan.withValues(alpha: 0.2),
                ),
                child: Slider(
                  value: _currentVal.clamp(widget.min, widget.max),
                  min: widget.min,
                  max: widget.max,
                  onChanged: (val) {
                    setState(() => _currentVal = val);
                    widget.onChanged(val);
                  },
                ),
              ),

              // Min / Max labels
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${widget.min.toStringAsFixed(widget.decimals)}${widget.unit}',
                      style: const TextStyle(fontSize: 9, color: StudioColors.textMuted),
                    ),
                    Text(
                      '${widget.max.toStringAsFixed(widget.decimals)}${widget.unit}',
                      style: const TextStyle(fontSize: 9, color: StudioColors.textMuted),
                    ),
                  ],
                ),
              ),

              // Presets row if provided
              if (widget.presets.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  alignment: WrapAlignment.center,
                  children: widget.presets.map((preset) {
                    final isCurrent = (_currentVal - preset.value).abs() < 0.01;
                    return ActionChip(
                      label: Text(
                        preset.label,
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                          color: isCurrent ? Colors.black : StudioColors.textSecondary,
                        ),
                      ),
                      backgroundColor: isCurrent
                          ? StudioColors.accentCyan
                          : StudioColors.backgroundDark,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                      onPressed: () {
                        setState(() => _currentVal = preset.value);
                        widget.onChanged(preset.value);
                      },
                    );
                  }).toList(),
                ),
              ],

              const SizedBox(height: 14),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: StudioColors.accentCyan,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text(
                  'APPLY & CLOSE',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
