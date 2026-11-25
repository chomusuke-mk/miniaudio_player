import 'package:material_ui/material_ui.dart';

import '../../core/preview/studio_preview.dart';
import '../../core/theme/studio_colors.dart';

/// Shared dark sub-card container used for toggleable DSP modules inside the
/// mastering card (such as silence skipping, crossfeed, stereo widener, reverb,
/// and the 10-band equalizer).
class DspSubCard extends StatelessWidget {
  /// Leading icon identifying the DSP effect module.
  final IconData icon;

  /// Concise module title displayed alongside the power toggle.
  final String title;

  /// Status summary line shown below the module header.
  final String subtitle;

  /// Whether the DSP processor is currently enabled.
  final bool enabled;

  /// Accent color applied to [icon], the `ON` label, and the active switch track.
  final Color accentColor;

  /// Invoked when the user toggles the module power switch.
  final ValueChanged<bool> onToggle;

  /// Interactive DSP controls disabled visually and interactively when `enabled` is `false`.
  final Widget child;

  /// Creates a toggleable [DspSubCard] wrapping [child] with [icon], [title],
  /// [subtitle], [enabled], [accentColor], and [onToggle].
  const DspSubCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.accentColor,
    required this.onToggle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF070B14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: StudioColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                size: 16,
                color: enabled ? accentColor : StudioColors.textMuted,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    enabled ? 'ON' : 'OFF',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: enabled ? accentColor : StudioColors.textMuted,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Switch(
                    value: enabled,
                    activeThumbColor: accentColor,
                    onChanged: onToggle,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            subtitle,
            style: const TextStyle(
              fontSize: 9.5,
              color: StudioColors.textSecondary,
            ),
          ),
          const SizedBox(height: 6),
          AnimatedOpacity(
            opacity: enabled ? 1.0 : 0.38,
            duration: const Duration(milliseconds: 200),
            child: IgnorePointer(ignoring: !enabled, child: child),
          ),
        ],
      ),
    );
  }
}

/// Preview showing enabled and disabled [DspSubCard] states side by side.
@StudioPreview(
  name: 'DSP SubCard (On/Off)',
  group: 'Shared Widgets',
  size: Size(360, 240),
)
Widget dspSubCardPreview() {
  return const Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      DspSubCard(
        icon: Icons.headphones,
        title: 'Bauer BS2B Crossfeed',
        subtitle: 'Active: 700Hz • 4.5dB crossfeed',
        enabled: true,
        accentColor: StudioColors.accentCyan,
        onToggle: StudioPreviewData.noopBool,
        child: Text(
          'Controls active',
          style: TextStyle(color: StudioColors.textPrimary, fontSize: 11),
        ),
      ),
      SizedBox(height: 10),
      DspSubCard(
        icon: Icons.surround_sound,
        title: 'Stereo Widener',
        subtitle: 'Inactive: standard Mid/Side spatializer field',
        enabled: false,
        accentColor: StudioColors.accentCyan,
        onToggle: StudioPreviewData.noopBool,
        child: Text(
          'Controls disabled',
          style: TextStyle(color: StudioColors.textMuted, fontSize: 11),
        ),
      ),
    ],
  );
}
