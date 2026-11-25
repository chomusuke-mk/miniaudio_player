import 'package:material_ui/material_ui.dart';

import '../../core/preview/studio_preview.dart';
import '../../core/theme/studio_colors.dart';

/// Compact key-value telemetry chip displaying a muted uppercase [label]
/// above a bold monospace [value].
class StudioMetricTile extends StatelessWidget {
  /// Short metric caption rendered above [value].
  final String label;

  /// Formatted metric readout text rendered in monospace font.
  final String value;

  /// Foreground highlight color for [value].
  final Color color;

  /// Font size applied to [value] (`12.0` compact or `18.0` KPI card).
  final double valueFontSize;

  /// Creates a [StudioMetricTile] displaying [label] and [value] colored with
  /// [color] and optional [valueFontSize].
  const StudioMetricTile({
    super.key,
    required this.label,
    required this.value,
    required this.color,
    this.valueFontSize = 12.0,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0F1D),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: StudioColors.cardBorder, width: 0.9),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 8.0,
              fontWeight: FontWeight.w700,
              color: StudioColors.textMuted,
              letterSpacing: 0.4,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 3),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: TextStyle(
                fontSize: valueFontSize,
                fontWeight: FontWeight.w800,
                fontFamily: 'monospace',
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Fixed-label monospace key-value row shared across analyzer and metadata
/// inspector cards.
class StudioPropertyRow extends StatelessWidget {
  /// Fixed-width attribute name shown on the left.
  final String label;

  /// Monospace value string shown on the right.
  final String value;

  /// Whether [value] represents an active background loading placeholder.
  final bool isLoading;

  /// Width reserved for [label] in logical pixels.
  final double labelWidth;

  /// Creates a [StudioPropertyRow] pairing [label] with [value], dimmed when
  /// [isLoading] is `true`, using [labelWidth] pixels for the caption column.
  const StudioPropertyRow({
    super.key,
    required this.label,
    required this.value,
    this.isLoading = false,
    this.labelWidth = 86,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: labelWidth,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 9,
                color: StudioColors.textMuted,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 9,
                color: isLoading ? const Color(0xFF64748B) : Colors.white,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Shared sub-panel header banner used inside analyzer and inspector cards.
class StudioSubCardHeader extends StatelessWidget {
  /// Leading icon displayed in [accentColor].
  final IconData icon;

  /// Accent color applied to [icon] and [title].
  final Color accentColor;

  /// Bold uppercase section title.
  final String title;

  /// Optional plain-text explanatory subtitle.
  final String? subtitle;

  /// Optional rich-text spans used instead of [subtitle] when styling inline fragments.
  final List<InlineSpan>? subtitleSpans;

  /// Optional trailing action or badge widget.
  final Widget? trailing;

  /// Creates a [StudioSubCardHeader] with [icon], [accentColor], [title], and
  /// optional [subtitle], [subtitleSpans], and [trailing].
  const StudioSubCardHeader({
    super.key,
    required this.icon,
    required this.accentColor,
    required this.title,
    this.subtitle,
    this.subtitleSpans,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final titleRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: accentColor),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            title,
            style: TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
              color: accentColor,
            ),
          ),
        ),
      ],
    );

    const subtitleStyle = TextStyle(
      fontSize: 8.5,
      color: StudioColors.textMuted,
      height: 1.3,
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFF0E1424),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(7)),
        border: Border(
          bottom: BorderSide(
            color: StudioColors.cardBorder.withValues(alpha: 0.6),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (trailing == null)
            titleRow
          else
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 2,
              children: [titleRow, trailing!],
            ),
          if (subtitleSpans != null) ...[
            const SizedBox(height: 3),
            Text.rich(
              TextSpan(style: subtitleStyle, children: subtitleSpans),
            ),
          ] else if (subtitle != null) ...[
            const SizedBox(height: 3),
            Text(subtitle!, style: subtitleStyle),
          ],
        ],
      ),
    );
  }
}

/// Preview showcasing [StudioMetricTile], [StudioPropertyRow], and
/// [StudioSubCardHeader].
@StudioPreview(
  name: 'Metric Tile & Property Row',
  group: 'Shared Widgets',
  size: Size(360, 220),
)
Widget studioMetricTilePreview() {
  return const Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      StudioSubCardHeader(
        icon: Icons.speed_outlined,
        accentColor: StudioColors.accentCyan,
        title: 'TELEMETRY SUMMARY',
        subtitle: 'Reusable sub-header, KPI tile, and monospace property rows',
      ),
      SizedBox(height: 8),
      StudioMetricTile(
        label: 'INTEGRATED LOUDNESS',
        value: '-12.2 LUFS',
        color: StudioColors.accentCyan,
        valueFontSize: 16,
      ),
      SizedBox(height: 6),
      StudioPropertyRow(label: 'Sample Rate', value: '48000 Hz'),
      StudioPropertyRow(label: 'Codec', value: 'FLAC 24-bit'),
    ],
  );
}
