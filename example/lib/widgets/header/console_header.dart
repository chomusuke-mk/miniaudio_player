import 'package:flutter/material.dart';

import '../../theme/studio_colors.dart';

enum ViewMode { studioConsole, audioAnalyzer, ingestMatrix }

class ConsoleHeader extends StatelessWidget {
  final ViewMode currentMode;
  final ValueChanged<ViewMode> onModeChanged;

  const ConsoleHeader({
    super.key,
    required this.currentMode,
    required this.onModeChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _buildModeTab(
          mode: ViewMode.studioConsole,
          label: 'Studio Master Console',
          icon: Icons.dashboard_outlined,
        ),
        _buildModeTab(
          mode: ViewMode.audioAnalyzer,
          label: 'Audio Analyzer',
          icon: Icons.analytics_outlined,
        ),
        _buildModeTab(
          mode: ViewMode.ingestMatrix,
          label: 'Ingest & Buffer Matrix',
          icon: Icons.layers_outlined,
        ),
      ],
    );
  }

  Widget _buildModeTab({
    required ViewMode mode,
    required String label,
    required IconData icon,
  }) {
    final isSelected = currentMode == mode;

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => onModeChanged(mode),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? StudioColors.accentCyan.withValues(alpha: 0.18)
              : StudioColors.cardBackgroundDark,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected
                ? StudioColors.accentCyan
                : StudioColors.cardBorder,
            width: 1.2,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: isSelected
                  ? StudioColors.accentCyan
                  : StudioColors.textSecondary,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                  color: isSelected
                      ? StudioColors.accentCyan
                      : StudioColors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
