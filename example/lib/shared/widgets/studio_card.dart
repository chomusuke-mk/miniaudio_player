import 'package:material_ui/material_ui.dart';

import '../../core/preview/studio_preview.dart';
import '../../core/theme/studio_colors.dart';
import 'studio_badge.dart';

/// Top-level studio card shell providing the dark card gradient, icon header,
/// responsive trailing slot, and collapsible body region.
class StudioCard extends StatelessWidget {
  /// Optional leading header icon rendered in [StudioColors.accentCyan].
  final IconData? icon;

  /// Uppercase or section header title text.
  final String title;

  /// Optional descriptive subtitle below [title].
  final String? subtitle;

  /// Optional trailing control widget or status badge row.
  final Widget? trailing;

  /// Main content rendered below the header when [showChild] is `true`.
  final Widget child;

  /// Internal padding surrounding the card contents.
  final EdgeInsetsGeometry padding;

  /// Maximum lines permitted for [subtitle], or `null` for unrestricted wrapping.
  final int? subtitleMaxLines;

  /// Whether [child] is displayed below the header.
  final bool showChild;

  /// Creates a [StudioCard] wrapping [child] with [title] and optional [icon],
  /// [subtitle], [trailing], [padding], [subtitleMaxLines], and [showChild].
  const StudioCard({
    super.key,
    this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    required this.child,
    this.padding = const EdgeInsets.all(16.0),
    this.subtitleMaxLines = 1,
    this.showChild = true,
  });

  /// Builds the expanded title and optional subtitle text column.
  Widget _buildTitleColumn() {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: StudioColors.textPrimary,
              letterSpacing: 0.3,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(
              subtitle!,
              style: const TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w500,
                color: StudioColors.textSecondary,
                height: 1.3,
              ),
              maxLines: subtitleMaxLines,
              overflow: subtitleMaxLines != null ? TextOverflow.ellipsis : null,
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: StudioColors.cardBorder, width: 1.2),
      ),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          gradient: StudioColors.cardGradient,
        ),
        padding: padding,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isNarrow = constraints.maxWidth < 360;
            final headerRow = Row(
              crossAxisAlignment: subtitleMaxLines == null
                  ? CrossAxisAlignment.start
                  : CrossAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Padding(
                    padding: subtitleMaxLines == null
                        ? const EdgeInsets.only(top: 1)
                        : EdgeInsets.zero,
                    child: Icon(icon, size: 18, color: StudioColors.accentCyan),
                  ),
                  const SizedBox(width: 8),
                ],
                _buildTitleColumn(),
                if (!isNarrow && trailing != null) ...[
                  const SizedBox(width: 8),
                  trailing!,
                ],
              ],
            );

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                headerRow,
                if (isNarrow && trailing != null) ...[
                  const SizedBox(height: 8),
                  Align(alignment: Alignment.centerLeft, child: trailing!),
                ],
                if (showChild) ...[
                  const SizedBox(height: 14),
                  child,
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Preview rendering [StudioCard] with header metadata and trailing badge.
@StudioPreview(
  name: 'Studio Card',
  group: 'Shared Widgets',
  size: Size(480, 180),
)
Widget studioCardPreview() {
  return const StudioCard(
    icon: Icons.graphic_eq,
    title: 'STUDIO MODULE CONTAINER',
    subtitle: 'Reusable gradient surface with adaptive trailing placement',
    trailing: StudioBadge(label: 'ACTIVE', color: StudioColors.accentEmerald),
    child: Text(
      'Module body content',
      style: TextStyle(color: StudioColors.textSecondary, fontSize: 12),
    ),
  );
}
