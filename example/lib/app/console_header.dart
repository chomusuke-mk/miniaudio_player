import 'package:material_ui/material_ui.dart';

import '../core/preview/studio_preview.dart';
import '../core/theme/studio_colors.dart';

/// Primary navigation sections displayed in the studio console header bar.
enum ViewMode {
  /// Multi-card live playback, DSP mastering, and hardware routing console.
  studioConsole,

  /// Single-pass BS.1770-4 audio analysis and pipeline telemetry view.
  audioAnalyzer,

  /// Static architecture diagram of the Rust ingest and buffer matrix.
  ingestMatrix,
}

/// Top navigation pill selector switching between [ViewMode] workspace tabs.
class ConsoleHeader extends StatelessWidget {
  /// Currently active [ViewMode] highlighted with cyan border styling.
  final ViewMode currentMode;

  /// Callback invoked when the user selects a different [ViewMode] tab.
  final ValueChanged<ViewMode> onModeChanged;

  /// Creates a [ConsoleHeader] displaying tabs for all [ViewMode] values with
  /// [currentMode] selected and dispatching selections to [onModeChanged].
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

  /// Builds a single navigation pill for [mode] displaying [icon] and [label].
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

/// Preview callback helper satisfying [ValueChanged] for [ConsoleHeader].
void _noopModeChanged(ViewMode _) {}

/// Preview displaying the [ConsoleHeader] navigation tabs.
@StudioPreview(
  name: 'Console Navigation Header',
  group: 'App Shell',
  size: Size(520, 72),
)
Widget consoleHeaderPreview() {
  return const ConsoleHeader(
    currentMode: ViewMode.studioConsole,
    onModeChanged: _noopModeChanged,
  );
}
