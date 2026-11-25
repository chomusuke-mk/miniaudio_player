import 'package:material_ui/material_ui.dart';

import '../../core/preview/studio_preview.dart';
import '../../core/theme/studio_colors.dart';

/// Compact bordered status pill used across studio cards and headers.
class StudioBadge extends StatelessWidget {
  /// Short label displayed inside the badge.
  final String label;

  /// Foreground and tinted border accent color for the pill.
  final Color color;

  /// Optional leading emoji prefix rendered before [label].
  final String? emoji;

  /// Creates a [StudioBadge] displaying [label] with an optional [color] and
  /// leading [emoji].
  const StudioBadge({
    super.key,
    required this.label,
    this.color = StudioColors.accentCyan,
    this.emoji,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 1.0),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            if (emoji != null) ...[
              TextSpan(text: '$emoji ', style: const TextStyle(fontSize: 10)),
            ],
            TextSpan(
              text: label,
              style: TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
                color: color,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// Preview showcasing [StudioBadge] accent color and emoji variants.
@StudioPreview(name: 'Studio Badges', group: 'Shared Widgets')
Widget studioBadgePreview() {
  return const Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      StudioBadge(
        label: 'O(1) Real-Time',
        emoji: '⚡',
        color: StudioColors.accentCyan,
      ),
      StudioBadge(label: 'Zero Contention', color: StudioColors.accentEmerald),
      StudioBadge(label: 'LIVE STREAM', color: StudioColors.accentRose),
      StudioBadge(label: 'MP3 320kbps', color: StudioColors.accentAmber),
    ],
  );
}
