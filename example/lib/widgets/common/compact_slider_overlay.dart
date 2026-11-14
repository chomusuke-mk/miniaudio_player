import 'package:flutter/material.dart';

import '../../theme/studio_colors.dart';

/// Ultra-compact, elegant floating slider overlay control for Speed, Pitch, Volume, Crossfeed, and DSP values.
///
/// Clicking the trigger button shows a sleek floating bar directly above it:
/// `[ Icon (click to reset to default) | ---------- Slider ---------- | Live Value ]`.
class CompactSliderControl extends StatefulWidget {
  final IconData icon;
  final String label;
  final double value;
  final double defaultValue;
  final double min;
  final double max;
  final Color activeColor;
  final ValueChanged<double> onChanged;
  final bool disabled;
  final bool showTriggerIcon;
  final String Function(double value)? valueFormatter;

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

class _CompactSliderControlState extends State<CompactSliderControl> {
  OverlayEntry? _overlayEntry;
  bool _isOpen = false;
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

  void _toggleOverlay() {
    if (widget.disabled) return;
    if (_isOpen) {
      _closeOverlay();
    } else {
      _showOverlay();
    }
  }

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
                // Fullscreen translucent barrier to dismiss on click outside
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _closeOverlay,
                  ),
                ),
                // Floating anchored slider bar directly above the trigger
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
                          // Reset icon: click snaps to default value
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
                          // Slider: slim neon track
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
