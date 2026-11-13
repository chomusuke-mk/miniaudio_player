import 'package:flutter/material.dart';

import '../../theme/studio_colors.dart';

/// Shared dark sub-card container used inside [DspEffectsCard] for toggleable
/// DSP modules (e.g. Smart Silence Skipping and Bauer BS2B Crossfeed).
class DspSubCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final Color accentColor;
  final ValueChanged<bool> onToggle;
  final Widget child;

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
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 9.5,
                        color: StudioColors.textSecondary,
                      ),
                    ),
                  ],
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
