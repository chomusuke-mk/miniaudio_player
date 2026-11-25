import 'package:material_ui/material_ui.dart';

import '../../core/preview/studio_preview.dart';
import '../../core/theme/studio_colors.dart';

/// Compact trigger pill that opens a floating slider overlay bar directly above
/// itself for adjusting continuous audio and DSP parameters.
///
/// Clicking the overlay's leading icon snaps the scalar back to [defaultValue].
class CompactSliderControl extends StatefulWidget {
  /// Icon rendered inside the pill (when [showTriggerIcon] is `true`) and as
  /// the reset button inside the floating slider overlay.
  final IconData icon;

  /// Compact trigger label text displayed inside the closed pill.
  final String label;

  /// Current numeric parameter value.
  final double value;

  /// Neutral reference value restored when tapping the overlay reset icon.
  final double defaultValue;

  /// Inclusive minimum slider bound.
  final double min;

  /// Inclusive maximum slider bound.
  final double max;

  /// Accent color for active tracks, border highlights, and formatted readout.
  final Color activeColor;

  /// Callback invoked whenever the slider value changes or resets.
  final ValueChanged<double> onChanged;

  /// Whether interaction is disabled and dimmed.
  final bool disabled;

  /// Whether [icon] is shown inside the closed trigger pill.
  final bool showTriggerIcon;

  /// Optional custom formatter converting a numeric `value` for the overlay readout.
  final String Function(double value)? valueFormatter;

  /// Creates a [CompactSliderControl] bound to [value], [defaultValue], [min],
  /// [max], [icon], [label], and [onChanged].
  const CompactSliderControl({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.defaultValue,
    required this.min,
    required this.max,
    this.activeColor = StudioColors.accentCyan,
    required this.onChanged,
    this.disabled = false,
    this.showTriggerIcon = true,
    this.valueFormatter,
  });

  @override
  State<CompactSliderControl> createState() => _CompactSliderControlState();
}

/// Manages the lifecycle and synchronization of the floating [OverlayEntry].
class _CompactSliderControlState extends State<CompactSliderControl> {
  /// Floating overlay entry inserted into the root overlay when expanded.
  OverlayEntry? _overlayEntry;

  /// Whether the floating slider bar is currently open on screen.
  bool _isOpen = false;

  /// Cached slider value updated interactively between external rebuilds.
  late double _currentVal;

  @override
  void initState() {
    super.initState();
    _currentVal = widget.value;
  }

  @override
  void didUpdateWidget(covariant CompactSliderControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.disabled && _isOpen) {
      _overlayEntry?.remove();
      _overlayEntry = null;
      _isOpen = false;
    }
    if (widget.value != oldWidget.value) {
      _currentVal = widget.value;
      if (_isOpen && _overlayEntry != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _isOpen) {
            _overlayEntry?.markNeedsBuild();
          }
        });
      }
    }
  }

  /// Toggles visibility of the anchored slider overlay unless disabled.
  void _toggleOverlay() {
    if (widget.disabled) return;
    if (_isOpen) {
      _closeOverlay();
    } else {
      _showOverlay();
    }
  }

  /// Formats [val] using [CompactSliderControl.valueFormatter] or falls back to [label].
  String _formatOverlayValue(double val) {
    if (widget.valueFormatter != null) {
      return widget.valueFormatter!(val);
    }
    final colonIdx = widget.label.indexOf(': ');
    if (colonIdx != -1) {
      return widget.label.substring(colonIdx + 2);
    }
    return widget.label;
  }

  /// Inserts an anchored floating slider bar into the nearest [Overlay].
  void _showOverlay() {
    final overlay = Overlay.of(context);
    _currentVal = widget.value;

    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final pos = renderBox.localToGlobal(Offset.zero);
    final screenSize = MediaQuery.of(context).size;

    final overlayWidth = 228.0.clamp(
      160.0,
      (screenSize.width - 16).clamp(160.0, 240.0),
    );
    final targetLeft = (pos.dx - 20).clamp(
      8.0,
      (screenSize.width - overlayWidth - 8).clamp(8.0, double.infinity),
    );
    final targetTop = (pos.dy - 44).clamp(
      8.0,
      (screenSize.height - 44).clamp(8.0, double.infinity),
    );

    _overlayEntry = OverlayEntry(
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setOverlayState) {
            return Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _closeOverlay,
                  ),
                ),
                Positioned(
                  left: targetLeft,
                  top: targetTop,
                  width: overlayWidth,
                  child: Material(
                    elevation: 10,
                    color: const Color(0xFF0D1424),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                      side: BorderSide(
                        color: widget.activeColor.withValues(alpha: 0.7),
                        width: 1.2,
                      ),
                    ),
                    child: Container(
                      height: 36,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Row(
                        children: [
                          IconButton(
                            icon: Icon(widget.icon, size: 16),
                            color: widget.activeColor,
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 28,
                              minHeight: 28,
                            ),
                            onPressed: () {
                              setOverlayState(() {
                                _currentVal = widget.defaultValue;
                              });
                              widget.onChanged(widget.defaultValue);
                            },
                          ),
                          Expanded(
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 2.5,
                                thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 5.5,
                                ),
                                activeTrackColor: widget.activeColor,
                                thumbColor: widget.activeColor,
                                inactiveTrackColor:
                                    StudioColors.cardBorderFocused,
                                overlayShape: const RoundSliderOverlayShape(
                                  overlayRadius: 10,
                                ),
                              ),
                              child: Slider(
                                value: _currentVal.clamp(
                                  widget.min,
                                  widget.max,
                                ),
                                min: widget.min,
                                max: widget.max,
                                onChanged: (val) {
                                  setOverlayState(() {
                                    _currentVal = val;
                                  });
                                  widget.onChanged(val);
                                },
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _formatOverlayValue(_currentVal),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: widget.activeColor,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    overlay.insert(_overlayEntry!);
    setState(() => _isOpen = true);
  }

  /// Removes the active floating slider overlay entry if present.
  void _closeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    if (mounted) {
      setState(() => _isOpen = false);
    }
  }

  @override
  void dispose() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final effectiveColor = widget.disabled
        ? StudioColors.textMuted
        : widget.activeColor;

    return InkWell(
      onTap: widget.disabled ? null : _toggleOverlay,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: widget.disabled
              ? StudioColors.backgroundDark.withValues(alpha: 0.5)
              : (_isOpen
                    ? widget.activeColor.withValues(alpha: 0.18)
                    : StudioColors.backgroundDark),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: widget.disabled
                ? StudioColors.cardBorder
                : (_isOpen
                      ? widget.activeColor
                      : StudioColors.cardBorderFocused),
            width: 1.0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.showTriggerIcon) ...[
              Icon(widget.icon, size: 14, color: effectiveColor),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: Text(
                widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: widget.disabled
                      ? StudioColors.textMuted
                      : (_isOpen ? Colors.white : StudioColors.textPrimary),
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Preview showing active and disabled [CompactSliderControl] trigger pills.
@StudioPreview(
  name: 'Compact Slider Pills',
  group: 'Shared Widgets',
  size: Size(360, 80),
)
Widget compactSliderControlPreview() {
  return const Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      CompactSliderControl(
        icon: Icons.volume_up,
        label: 'Vol: 100%',
        value: 1.0,
        defaultValue: 1.0,
        min: 0.0,
        max: 2.0,
        activeColor: StudioColors.accentEmerald,
        onChanged: StudioPreviewData.noopDouble,
      ),
      CompactSliderControl(
        icon: Icons.speed,
        label: '1.25x',
        value: 1.25,
        defaultValue: 1.0,
        min: 0.25,
        max: 4.0,
        activeColor: StudioColors.accentCyan,
        onChanged: StudioPreviewData.noopDouble,
      ),
      CompactSliderControl(
        icon: Icons.tune,
        label: 'Disabled',
        value: 0.0,
        defaultValue: 0.0,
        min: -12.0,
        max: 12.0,
        disabled: true,
        onChanged: StudioPreviewData.noopDouble,
      ),
    ],
  );
}
