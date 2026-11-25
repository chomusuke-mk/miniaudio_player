import 'package:material_ui/material_ui.dart';

import '../core/preview/studio_preview.dart';
import '../core/theme/studio_colors.dart';
import '../shared/widgets/studio_badge.dart';

/// Top application bar displaying the `miniaudio_player` branding and engine
/// capability badges on wide viewports.
class StudioAppBar extends StatelessWidget implements PreferredSizeWidget {
  /// Creates a [StudioAppBar] with fixed `68.0` toolbar height.
  const StudioAppBar({super.key});

  @override
  Size get preferredSize => const Size.fromHeight(68);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      toolbarHeight: 68,
      backgroundColor: const Color(0xFF070B14),
      elevation: 0,
      titleSpacing: 16.0,
      title: LayoutBuilder(
        builder: (context, constraints) {
          final isCompact = constraints.maxWidth < 700;
          return Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 24,
                          height: 24,
                          child: Image.asset(
                            'assets/icon.png',
                            width: 24,
                            height: 24,
                            errorBuilder: (context, error, stackTrace) =>
                                const Icon(
                                  Icons.graphic_eq,
                                  color: StudioColors.accentCyan,
                                  size: 24,
                                ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: ShaderMask(
                              shaderCallback: (bounds) =>
                                  StudioColors.titleGradient
                                      .createShader(bounds),
                              child: const Text(
                                'miniaudio_player',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w900,
                                  color: Colors.white,
                                  letterSpacing: -0.5,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      'Ultra-Low-Resource Native Audio Engine & DSP Architecture for Flutter & Dart',
                      style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w500,
                        color: StudioColors.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (!isCompact) ...[
                const SizedBox(width: 12),
                const Flexible(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    alignment: WrapAlignment.end,
                    children: [
                      StudioBadge(
                        label: 'O(1) Real-Time & 0 Heap Alloc',
                        emoji: '⚡',
                        color: StudioColors.accentCyan,
                      ),
                      StudioBadge(
                        label: '100% Pure Dart FFI',
                        emoji: '🔀',
                        color: StudioColors.accentViolet,
                      ),
                      StudioBadge(
                        label: 'Hardware Limiter',
                        emoji: '🛡️',
                        color: StudioColors.accentAmber,
                      ),
                      StudioBadge(
                        label: 'Studio Reverb',
                        emoji: '🏛️',
                        color: StudioColors.accentEmerald,
                      ),
                    ],
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// Preview rendering [StudioAppBar] at desktop width.
@StudioPreview(
  name: 'Studio App Bar',
  group: 'App Shell',
  size: Size(920, 92),
)
Widget studioAppBarPreview() => const StudioAppBar();
