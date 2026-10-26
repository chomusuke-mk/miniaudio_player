import 'package:flutter/material.dart';
import '../../theme/studio_colors.dart';

class StudioBadge extends StatelessWidget {
  final String label;
  final Color color;
  final String? emoji;

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
        border: Border.all(
          color: color.withValues(alpha: 0.35),
          width: 1.0,
        ),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            if (emoji != null) ...[
              TextSpan(
                text: '$emoji ',
                style: const TextStyle(fontSize: 10),
              ),
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
