import 'package:flutter/material.dart';

import '../../theme/studio_colors.dart';

class StudioCard extends StatelessWidget {
  final IconData? icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;
  final EdgeInsetsGeometry padding;
  final int? subtitleMaxLines;
  final bool showChild;

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
